# -*- coding: utf-8 -*-

# Main Sinatra file where the app is bootstrapped and routes are defined.
# Most configuration and all the business logic resides in lib/

require 'sinatra'
require 'sinatra/config_file'
require 'sinatra/partial'
require 'json'
require 'mongo'
require 'will_paginate/collection'
require "will_paginate-bootstrap"
require 'cgi'
# require 'gabba' uncomment to use Google Analytics
require 'rack-session-mongo'
require 'rack-flash'
require 'omniauth-orcid'
require 'oauth2'
require 'resque'
require 'open-uri'
require 'uri'


# Set up logging
require 'log4r'
include Log4r
logger = Log4r::Logger.new('test')
logger.trace = true
logger.level = DEBUG
formatter = Log4r::PatternFormatter.new(:pattern => "[%l] %t  %M")
Log4r::Logger['test'].outputters << Log4r::Outputter.stdout
Log4r::Logger['test'].outputters << Log4r::FileOutputter.new('logtest', 
                                              :filename =>  'log/app.log',
                                              :formatter => formatter)
logger.info 'got log4r set up'
logger.debug "This is a message with level DEBUG"
logger.info "This is a message with level INFO"
use Rack::Logger, logger


config_file 'config/settings.yml'

require_relative 'lib/configure'
require_relative 'lib/helpers'
require_relative 'lib/bootstrap'
require_relative 'lib/session'
require_relative 'lib/data'
require_relative 'lib/orcid_update'
require_relative 'lib/orcid_claim' ## CHANGE to orcid_add_externalid or similar

MIN_MATCH_SCORE = 2
MIN_MATCH_TERMS = 3
MAX_MATCH_TEXTS = 1000

after do
  response.headers['Access-Control-Allow-Origin'] = '*'
end

before do
  logger.info "Fetching #{url}, params " + params.inspect
  load_config
end

get '/' do

  # If the user is signed in via ORCID, kick off a search. Otherwise show the splash page.
  if !signed_in?
    erb :splash, :locals => {:page => {:query => ""}}
  else

    # Before doing anything else, make sure that there is a local Mongo record for this ORICD, as this 
    # may not have been created if user is logging in for the first time.
    @orcid_record = settings.orcids.find_one({:orcid => sign_in_id})
    if @orcid_record.nil?
      logger.info "Creating new Mongo record for ORCID #{session[:orcid][:uid]}"
      @orcid_record = OrcidUpdate.perform(session_info)
    end

    q = ""
    if !params.has_key?('q') or params['q'] == ""
      # If user doesn't provide a query string, make one  based on names pulled from his ORCID profile
      logger.info "Building query parameters for auto search, based on names from ORCID profile data in session: \n" + session[:orcid][:info].ai
      q = [session[:orcid][:info][:name]]
      unless session[:orcid][:info][:other_names].nil?
        session[:orcid][:info][:other_names].each {|n| q.push n}
      end

      # Split up each name and create a 'surname,firstname/initials' query expression, to better work with ISNI search API
      q.map! do |n|
        # crude logic here: the surname is assumed to be the last word in the name string
        (rest, given_name) = n.match(/^(.+) (\S+)$/)
        !given_name.nil?  ? "#{given_name}, #{rest}" :  n 
      end

      logger.debug "q array of names from ORCID profile: " + q.ai
    else
      # Otherwise build a query string based on uber-simple boolean OR syntax
      q = params['q'].split(/\s+or\s+/i).map{|n| n}
    end

    page           = query_page
    items_per_page = query_items


    # Before doing the search, make sure that there is a local Mongo record for this ORICD, as this 
    # may not have been created if user is logging in for the first time.
    @orcid_record = settings.orcids.find_one({:orcid => sign_in_id})
    if @orcid_record.nil?
      logger.info "Creating new Mongo record for ORCID #{session[:orcid][:uid]}"
      OrcidUpdate.perform(session_info)
      @orcid_record = settings.orcids.find_one({:orcid => sign_in_id})        
    end
    
    @total_items = 0 # this gets populated in the search() helper method, IF search picks up one or more records
    results = search settings.server, q
    if @total_items > 0
      logger.debug "Full set of total @{total_items} search results:\n" + results.ai
    elsif
      logger.debug "Nothing found"
    end

    # Set up a paged collection representing the set of search results
    items = WillPaginate::Collection.create(page, items_per_page, @total_items) do |pager|      
      pager.replace(results)
    end

    results_page = {
      :bare_sort => params['sort'],
      :bare_query => q.join(" OR "),
      :query => q,
      :bare_filter => params['filter'],
      :page => page,
      :items => items
    }

    logger.debug "Rendering search results"
    erb :results, :locals => {page: results_page}
  end
end


get '/help/search' do
  page = {:query => ''}
  erb :search_help, :locals => {page: page}
end

get '/orcid/activity' do
  if signed_in?
    page = {:query => ''}
    erb :activity, :locals => {page: page}
  else
    redirect '/'
  end
end

get '/orcid/claim' do
  status = 'oauth_timeout'

  if signed_in? && params['id']
    id      = params['id'] # The external ID
    work_id = params['work_id'] # The work ID, if user is claiming a work
    orcid_record = settings.orcids.find_one({:orcid => sign_in_id})
    
    is_work = params['is_work'] == 'true' ? true : false
    id_type = nil
    already_added = false
    if is_work
      id_type = "ISBN" # ATTN hardcoding to ISBNs here, for now
      already_added = orcid_record['work_ids'].any? {|h| h['id'] == id && h['type'] == id_type }
    else
      id_type = "ISNI"
      work_id = nil
      already_added = false
      unless orcid_record['external_ids'].nil?
        already_added = orcid_record['external_ids'].any? {|h| h['id'] == id && h['type'] == 'ISNI' }
      end
    end
    
    if already_added
      logger.info "#{id_type} identifier #{id} is already claimed, not doing anything!"
      status = 'ok'
    else
      logger.info "Unclaimed #{id_type} identifier #{id}, so initiating claim by ORCID #{sign_in_id}"

      # Grab the external bio record, we'll need this info either way
      bio_record = settings.bios.find_one({:id => id})
      if !bio_record
        status = 'no_such_id'
        logger.warn "No bio record found for external ID #{id}"
      else
        logger.debug "Got some bio metadata: " + bio_record.ai
      end

      # Grab the work record if user is claiming a work associated with the external ID (the bio-record) in hand
      if !work_id.nil?
        work_record = {'identifier' => work_id}
        lookup_and_add_isbn_metadata! work_record
        logger.debug "Got some work metadata: " + work_record.ai
      end
          
      # Let's begin the claim process
      claim_ok = false
      begin
        claim_ok = OrcidClaim.perform(session_info, bio_record, work_record) 
      rescue => e
        logger.error "Error message from claim process: #{e}: \n"

        # Supply some reasonably human-friendly error messaging here, at least for the 
        #common claim-failure scenarios
        status = case e.to_s
                 when /Insufficient or wrong scope/i
                   "oauth_timeout"
                   # [can catch more messages with additional when's, and add corresponding messaging in itemlist.js]
                 when /Write scopes for this token have expired/i
                   "oauth_timeout"                   
                 else
                   "API error: #{e}"
                 end
      end

      # Update MongoDB record for this ORCID
      # TODO shove this update logic into a helper method OR the orcid_claim.rb module
      if claim_ok
        if orcid_record
          orcid_record['updated'] = true
          orcid_record['locked_ids'] << id
          orcid_record['locked_ids'].uniq!
          settings.orcids.save(orcid_record)
        else
          doc = {:orcid => sign_in_id, :ids => [], :locked_ids => [id]}
          settings.orcids.insert(doc)
        end
        
        # The ID could have been added as limited or public. If so we need to tell the UI.
        OrcidUpdate.perform(session_info)
        status = 'ok_visible'

        # NB for now, ignoring the limited vs. public issue and assume the user has his
        # external IDs publicly visible.        

        #updated_orcid_record = settings.orcids.find_one({:orcid => sign_in_id})        
        #if updated_orcid_record['external_ids'].include?(id)
        #  status = 'ok_visible'
        #else
        #  status = 'ok'
        #end
      end
    end
  end
  
  content_type 'application/json'
  {:status => status}.to_json
end

get '/orcid/unclaim' do
  if signed_in? && params['id']
    id = params['id']

    logger.info "Initiating unclaim for #{id}"    
    orcid_record = settings.orcids.find_one({:orcid => sign_in_id})

    if orcid_record
      orcid_record['locked_ids'].delete(id)
      settings.orcids.save(orcid_record)
    end
  end

  content_type 'application/json'
  {:status => 'ok'}.to_json
end

get '/orcid/sync' do
  status = 'oauth_timeout'

  if signed_in?
    logger.debug "user is still logged in, updating ORCID profile data"
    if OrcidUpdate.perform(session_info)
      logger.info "Updated ORCID info went OK"
      status = 'ok'
    else
      logger.warn "Problem with updating ORCID info!"
      status = 'oauth_timeout'
    end
  end

  content_type 'application/json'
  {:status => status}.to_json
end

get '/works/list' do

  status = 'oauth_timeout'
  
  if signed_in? && params['id']
    id = params['id']
    
    # Fetch ORCID and external bio metadata
    orcid_record = settings.orcids.find_one({:orcid => sign_in_id})   
    logger.debug "Retrieved ORCID profile data for " + sign_in_id + ": " + orcid_record.ai
    bio_record = settings.bios.find_one({:id => id})
    if !bio_record
      status = 'no_such_id'
      logger.warn "No bio record found for #{id}"
    else       
      logger.debug "Retrieved bio metadata for #{id} from MongoDB: " + bio_record.ai      
    end

    # For each work identifier at hand, look up metadata if we can
    works = []
    bio_record['works'].each do |work|
      
      # ATTN!! For now, we only grab metadata for books which have ISBNs
      # ToDo?? only fetch metadata if we haven't already done this previously and cached locally
      if work['identifierType'] == 'ISBN'
        lookup_and_add_isbn_metadata! work

        # TODO: check against list of work IDs in profile to see if user has claimed this work already
        # get list from profile
        claimed = false
        claimed_work_ids = orcid_record['work_ids']
        unless claimed_work_ids.nil?
          claimed = claimed_work_ids.any? {|h| h["id"] == work['identifier'] && h["type"] == work['identifierType'] }
        end
        work['claimed'] = claimed
        logger.debug "Got final work identifier metadata: " + work.ai
        works << work
      end
    end
    works.size == 0 and return "No works found"    

    logger.debug "final works hash: " + works.ai
    
    # Finally pass set of works w/ titles etc. (same hash?) to template which renders the work list    
    page = {:query => '', :works => works}
    erb :work_list, :layout => false, :locals => {page: page}
    
    # [gera annarsstadar, helper eda Claim class? ]
    # gera more flexible orcid setup, external_ids (type+value)  vs. work_ids o.s.fr.
    
  end
end

get '/auth/orcid/callback' do
  session[:orcid] = request.env['omniauth.auth']
  logger.info "Signing in via ORCID #{session[:orcid][:uid]}, got session info:\n" + session.ai
  if orcid_record = OrcidUpdate.perform(session_info)
    logger.info "Updated ORCID info went OK, ended with this record: " + orcid_record.ai
    status = 'ok'

    # add name info to session so it's close at hand
    session[:orcid][:info][:name] = "#{orcid_record['given_name']} #{orcid_record['family_name']}"
    session[:orcid][:info][:other_names] = orcid_record['other_names'] || []
    logger.debug "session data after login & profile sync: " + session.ai    
  else
    logger.warn "Problem with updating ORCID info for user #{session[:orcid][:uid]} !!"
    status = 'oauth_timeout'
  end

  #Resque.enqueue(OrcidUpdate, session_info)
  erb :auth_callback
end

get '/auth/orcid/check' do

end

# Used to sign out a user but can also be used to mark that a user has seen the
# 'You have been signed out' message. Clears the user's session cookie.
get '/auth/signout' do
  session.clear
  redirect(params[:redirect_uri])
end

get "/auth/failure" do
  flash[:error] = "Authentication failed with message \"#{params['message']}\"."
  erb :auth_callback
end

get '/auth/:provider/deauthorized' do
  haml "#{params[:provider]} has deauthorized this app."
end

get '/heartbeat' do
  content_type 'application/json'

  params['q'] = 'fish'

  begin
    # Attempt a query with solr
    solr_result = select(search_query)

    # Attempt some queries with mongo
    result_list = search_results(solr_result)

    {:status => :ok}.to_json
  rescue StandardError => e
    {:status => :error, :type => e.class, :message => e}.to_json
  end
end
