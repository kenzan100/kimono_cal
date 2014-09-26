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
require 'rest_client'
require 'chronic'

enable :sessions

CREDENTIAL_STORE_FILE = "#{$0}-oauth2.json"
JSON_FILE_NAME = "start_a_startup_school_kimono_data.json"

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

post '/kimono' do
  api_id = params[:api_id]
  response = RestClient.get "https://www.kimonolabs.com/api/#{api_id}?apikey=#{ENV['KIMONO_API_KEY']}"
  if params[:cal_parser]
    kimono_hash = JSON.parse response
    api_name = kimono_hash["name"]
    response = KIMONO_API_LIST[api_name][:parser].call(kimono_hash).to_json
  end
  response = JSON.parse(response).to_json
  [200, {'Content-Type' => 'application/json'}, response]
end

get '/apis' do
  result = api_client.execute(api_method: calendar_api.calendar_list.list,
                              parameters: { 'calendarId' => ENV['CAL_ID'] },
                              authorization: user_credentials)
  unless result.status == 200
    return [result.status, {'Content-Type' => 'application/json'}, JSON.parse(result.body).to_json]
  end
  @kimono_api_list = KIMONO_API_LIST.map{|label, values| [label, values[:api_id]] }
  @calendar_list   = result.data.items.map{|item| [item.summary, item.id]}
  erb :available_apis
end

get '/' do
  "go to available endpoints directly."
end

post '/' do
  api_id = params[:api_id]
  kimono_json = RestClient.get "https://www.kimonolabs.com/api/#{api_id}?apikey=#{ENV['KIMONO_API_KEY']}"
  kimono_hash = JSON.parse kimono_json
  api_name = kimono_hash["name"]
  kimono_result = KIMONO_API_LIST[api_name][:parser].call(kimono_hash)

  cal_id = params[:calendar_id]
  result = api_client.execute(api_method: calendar_api.events.list,
                              parameters: { 'calendarId' => cal_id },
                              authorization: user_credentials)
  formatted_result = {}
  result.data.items.each{|item|
    formatted_result[item.start.date] = item.id
    formatted_result[item.start.date_time] = item.id
  }
  formatted_result.reject!{|k,v| k.nil?}

  unless result.status == 200
    return [result.status, {'Content-Type' => 'application/json'}, JSON.parse(result.body).to_json]
  end

  batch = Google::APIClient::BatchRequest.new
  kimono_result.each do |req|
    method     = "calendar_api.events.insert"
    parameters = {'calendarId' => cal_id}
    if formatted_result[req["start"]["date"]] || (req["start"]["dateTime"] && formatted_result[Time.parse(req["start"]["dateTime"])])
      method = "calendar_api.events.patch"
      parameters['eventId'] = formatted_result[req["start"]["date"]] || formatted_result[Time.parse(req["start"]["dateTime"])]
    end
    batch.add(api_method: eval(method),
              parameters: parameters,
              authorization: user_credentials,
              body_object: req,
              headers: {'Content-Type' => 'application/json'})
  end
  result = api_client.execute(batch)
  output = result.request.calls.map do |res|
    method = res[1].api_method.id
    body = res[1].body
    [method, body]
  end
  [result.status, {'Content-Type' => 'application/json'}, output.to_json]
end

#####PARSERS
PARSER_START_UP_SCHOOL = Proc.new do |kimono_json|
  kimono_json_without_header = kimono_json["results"]["classes"].drop(1) #omit header
  kimono_result = kimono_json_without_header.map do |a_class|
    date = a_class["date"]
    description = ""
    if date.is_a?(Hash)
      description += "#{date.fetch("href","")}\n"
      date = date["text"]
    end
    date_arr = date.split("/")
    year  = "20" + date_arr[-1]
    month = "%02d" % date_arr[0].to_i
    day   = "%02d" % date_arr[1].to_i
    formatted_date = [year,month,day].join("-")
    { 'summary'     => a_class["topic"]["text"],
      'description' => description += "#{a_class["speaker"]}\n\n#{a_class["topic"]["href"]}",
      'start'       => {'date' => formatted_date},
      'end'         => {'date' => formatted_date} }
  end
  kimono_result
end

PARSER_AKB48_SCHEDULE = Proc.new do |kimono_json|
  kimono_json["results"]["akb48_theater_detailed_schedule"].map do |a_show|
    start_time = a_show["detailed_info"].match(/(\d|:)+/)[0] # assumed format "18:30~"
    time = "#{a_show["date"]} #{start_time}"
    start_datetime = Chronic.parse time
    end_datetime = Chronic.parse('2 hours from now', now: start_datetime)
    { 'summary'     => a_show["team"]["alt"],
      'description' => "#{a_show["detailed_info"]}\n\n※公演時間は2時間として仮定しています。",
      'start'       => {'dateTime' => start_datetime.strftime('%FT%T%:z')},
      'end'         => {'dateTime' => end_datetime.strftime('%FT%T%:z')} }
  end
end

KIMONO_API_LIST = {
  "start_a_startup_course_schedule" => { api_id: "5bpn6e0g", parser: PARSER_START_UP_SCHOOL },
  "akb48_theater_detailed_schedule" => { api_id: "67vq5vuy", parser: PARSER_AKB48_SCHEDULE  }
}
