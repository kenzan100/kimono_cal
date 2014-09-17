require 'rubygems'
require 'google/api_client'
require 'google/api_client/client_secrets'
require 'google/api_client/auth/file_storage'
require 'sinatra'
require 'sinatra/reloader' if development?
require 'logger'
require 'byebug' if development?
require 'date'
require 'json'

enable :sessions

CREDENTIAL_STORE_FILE = "#{$0}-oauth2.json"

def logger; settings.logger end
def api_client; settings.api_client; end
def calendar_api; settings.calendar; end

def user_credentials
  # Build a per-request oauth credential based on token stored in session
  # which allows us to use a shared API client.
  @authorization ||= (
    auth = api_client.authorization.dup
    auth.redirect_uri = to('/oauth2callback')
    auth.update_token!(session)
    auth
  )
end

configure do
  log_file = File.open('calendar.log', 'a+')
  log_file.sync = true
  logger = Logger.new(log_file)
  logger.level = Logger::DEBUG

  client = Google::APIClient.new(
    :application_name => 'Ruby Calendar sample',
    :application_version => '1.0.0'
  )

  file_storage = Google::APIClient::FileStorage.new(CREDENTIAL_STORE_FILE)
  if file_storage.authorization.nil?
    client_secrets = Google::APIClient::ClientSecrets.load
    client.authorization = client_secrets.to_authorization
    client.authorization.scope = 'https://www.googleapis.com/auth/calendar'
  else
    client.authorization = file_storage.authorization
  end

  # Since we're saving the API definition to the settings, we're only retrieving
  # it once (on server start) and saving it between requests.
  # If this is still an issue, you could serialize the object and load it on
  # subsequent runs.
  calendar = client.discovered_api('calendar', 'v3')

  set :logger, logger
  set :api_client, client
  set :calendar, calendar
end

before do
  # Ensure user has authorized the app
  unless user_credentials.access_token || request.path_info =~ /\A\/oauth2/
    redirect to('/oauth2authorize')
  end
end

after do
  # Serialize the access/refresh token to the session and credential store.
  session[:access_token] = user_credentials.access_token
  session[:refresh_token] = user_credentials.refresh_token
  session[:expires_in] = user_credentials.expires_in
  session[:issued_at] = user_credentials.issued_at

  file_storage = Google::APIClient::FileStorage.new(CREDENTIAL_STORE_FILE)
  file_storage.write_credentials(user_credentials)
end

get '/oauth2authorize' do
  # Request authorization
  redirect user_credentials.authorization_uri.to_s, 303
end

get '/oauth2callback' do
  # Exchange token
  user_credentials.code = params[:code] if params[:code]
  user_credentials.fetch_access_token!
  redirect to('/')
end

get '/' do
  result = api_client.execute(api_method: calendar_api.events.list,
                              parameters: {
                                'calendarId' => ENV['CAL_ID'],
                              }, authorization: user_credentials)
  formatted_result = {}
  result.data.items.each{|item| formatted_result[item.start.date] = item.id }
  formatted_result.reject!{|k,v| k.nil?}

  file = File.read "start_a_startup_school_kimono_data.json"
  kimono_json = JSON.parse file
  kimono_json_without_header = kimono_json["results"]["classes"].drop(1) #omit header
  kimono_result = kimono_json_without_header.map do |a_class|
    date = a_class["date"]
    date_arr = date.split("/")
    year  = "20" + date_arr[-1]
    month = "%02d" % date_arr[0].to_i
    day   = "%02d" % date_arr[1].to_i
    formatted_date = [year,month,day].join("-")
    { 'summary'     => a_class["topic"]["text"],
      'description' => "#{a_class["speaker"]}\n\n#{a_class["topic"]["href"]}",
      'start'       => {'date' => formatted_date},
      'end'         => {'date' => formatted_date} }
  end

  batch = Google::APIClient::BatchRequest.new
  kimono_result.each do |req|
    method     = "calendar_api.events.insert"
    parameters = {'calendarId' => ENV['CAL_ID']}
    if formatted_result[req["start"]["date"]]
      method = "calendar_api.events.patch"
      parameters['eventId'] = formatted_result[req["start"]["date"]]
    end
    batch.add(api_method: eval(method),
              parameters: parameters,
              authorization: user_credentials,
              body_object: req)
  end
  result = api_client.execute(batch)
  [result.status, {'Content-Type' => 'application/json'}, result.data.to_json]
end