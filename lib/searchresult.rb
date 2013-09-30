# -*- coding: utf-8 -*-

require 'cgi'
require 'log4r'

# Mixin which brings functionality common to the various types of search. 


module SearchResult # ?? rename to SearchService or somesuch??

  # Abstract methods that including classes need to implement if they're to be used
  def self.build_query
    raise NotImplementedError
  end

  def self.parse_results
    raise NotImplementedError    
  end
  
  # Set up regular HTTP connection to a RESTful API. Some subclasses will tweak this
  def self.connect url
    Faraday.new(:url => url) do |c|
      c.use FaradayMiddleware::FollowRedirects, :limit => 5
      c.adapter :net_http
      c.headers = {'Accept' => "application/xml"}      
    end
  end


  # Adding new or updating existing record in MongoDB
  
  # Paged result sets
  
end

