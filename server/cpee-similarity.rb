#!/usr/bin/ruby
require 'riddl/server'
require 'riddl/client'
require 'xml/smart'
require 'json'
require_relative '../lib/cpee/similarity/sim_options'

class Similarity < Riddl::Implementation #{{{
  include SimOptions
  def response
    #get parameters
    begin
      input_cpee1 = @p[0].value.read
      input_cpee2 = @p[1].value.read
      sim_type = @p[2].value.read
      threshold = @p[3]&.value&.read
      #doc1 = XML::Smart.string(input_cpee1)
      #doc2 = XML::Smart.string(input_cpee2)
    rescue Exception => e
      @status = 400
      return Riddl::Parameter::Complex.new("similarity_out","application/json",{:error => e}.to_json())
    end

    #begin
    similarity = send("#{sim_type}_similarity".to_sym,input_cpee1,input_cpee2,threshold)[0]
    #rescue Exception => e
    #  @status = 500
    #  return Riddl::Parameter::Complex.new("similarity_out","application/json",{:error => e.message}.to_json())
    #end

    return(Riddl::Parameter::Complex.new("similarity_out","application/json",{:sim_type => sim_type, :similarity => similarity}.to_json()))
  end
end #}}}

Riddl::Server.new(File.dirname(__FILE__) + '/cpee-similarity.xml', :port => 9325) do
  accessible_description true
  cross_site_xhr true

  on resource do
    run Similarity if get 'similarity_in'
  end
end.loop!

