require 'faraday'
require 'faraday_middleware'

require 'log4r'


configure do

  def logger
    Log4r::Logger['test']    
  end

  
  set :logging, Logger::INFO

  # Work around rack protection referrer bug
  set :protection, :except => :json_csrf
  
  # Configure template engine for partials
  set :partial_template_engine, :erb

  # Configure API connection to remote service
  logger.info "Configuring remote search API, connecting to " + settings.server_url
  server = Faraday.new(:url => settings.server_url) do |c|
    logger.debug c.ai
    c.use FaradayMiddleware::FollowRedirects, :limit => 5
    c.adapter :net_http
    c.headers = {'Accept' => "application/xml"}
  end
  set :server, server
  
  # Configure Mongo for local storage
  logger.info "Configuring Mongo: url=" + settings.mongo_host  
  set :mongo, Mongo::Connection.new(settings.mongo_host)
  set :works, settings.mongo[settings.mongo_db]['works']
  set :bios, settings.mongo[settings.mongo_db]['bios']
  set :claims, settings.mongo[settings.mongo_db]['claims']
  set :orcids, settings.mongo[settings.mongo_db]['orcids']

  # Set facet fields
  set :facet_fields, ['type', 'something else']


  # Google analytics event tracking
  set :ga, Gabba::Gabba.new(settings.gabba[:cookie], settings.gabba[:url]) if settings.gabba[:cookie]

  # Orcid endpoint
  logger.info "Configuring ORCID, client app ID #{settings.orcid[:client_id]} connecting to #{settings.orcid[:site]}"
  set :orcid_service, Faraday.new(:url => settings.orcid[:site])

  # Orcid oauth2 object we can use to make API calls
  set :orcid_oauth, OAuth2::Client.new(settings.orcid[:client_id],
                                       settings.orcid[:client_secret],
                                       {:site => settings.orcid[:site]})

  # Set up session and auth middlewares for ORCID sign in, including the OAuth scope to request authz from user
  use Rack::Session::Mongo, settings.mongo[settings.mongo_db]
  use Rack::Flash
  use OmniAuth::Builder do
    provider :orcid, settings.orcid[:client_id], settings.orcid[:client_secret],
    :authorize_params => {
      :scope => '/orcid-profile/read-limited /orcid-bio/external-identifiers/create /orcid-works/create'
    },
    :client_options => {
      :site => settings.orcid[:site],
      :authorize_url => settings.orcid[:authorize_url],
      :token_url => settings.orcid[:token_url],
    },
    :provider_ignores_state => true
  end
  OmniAuth.config.logger = logger

  set :show_exceptions, true
end


