# Kimono Cal

using [Kimono Lab](https://www.kimonolabs.com),
"Kimono Cal" imports html structured schedule into Google Calendar.

much of Google Calendar API code is from
[Google's example](https://github.com/google/google-api-ruby-client-samples/tree/master/calendar)


##Precaution

* currently, it uses "start_a_startup_course_schedule.json" locally and
* heavily depends on its structure for parsing.
* I may be fixing this for broader usages, but not for sure.


## Setup

###please follow Google's ["Setup Authentication"](https://github.com/google/google-api-ruby-client-samples/tree/master/calendar) instruction in order to use it.

* git clone xxx
* bundle install
* follow the [auth instruction](https://github.com/google/google-api-ruby-client-samples/tree/master/calendar)
* bundle exec ruby calendar.rb
* go to 'http://localhost:4567' for authentication and import.
