require 'net/https'
require 'base64'
require 'rexml/document'
require 'hmac-sha1' # this is a gem

class CloudfrontInvalidator  
  API_VERSION = '2012-05-05'
  BASE_URL = "https://cloudfront.amazonaws.com/#{API_VERSION}/distribution/"
  DOC_URL = "http://cloudfront.amazonaws.com/doc/#{API_VERSION}/"
  BACKOFF_LIMIT = 512
  BACKOFF_DELAY = 0.025

  def initialize(aws_key, aws_secret, cf_dist_id, args = {})
    @aws_key, @aws_secret, @cf_dist_id = aws_key, aws_secret, cf_dist_id
    @backoff_limit = args[:backoff_limit] || BACKOFF_LIMIT
  end
  
  def invalidate(*keys)
    keys = keys.flatten.map do |k| 
      k.start_with?('/') ? k : '/' + k 
    end
    
    uri = URI.parse "#{BASE_URL}#{@cf_dist_id}/invalidation"
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    body = xml_body(keys)

    delay = 1
    begin
      resp = http.send_request 'POST', uri.path, body, headers
      doc = REXML::Document.new resp.body
   
      # Create and raise an exception for any error the API returns to us.
      if resp.code.to_i != 201
        error_code = doc.elements["ErrorResponse/Error/Code"].text
        self.class.const_set(error_code,Class.new(StandardError)) unless self.class.const_defined?(error_code.to_sym)
        raise self.class.const_get(error_code).new(doc.elements["ErrorResponse/Error/Message"].text)
      end
    
    # Handle the common case of too many in progress by waiting until the others finish.
    rescue TooManyInvalidationsInProgress => e
      STDERR.puts e.inspect
      unless delay >= @backoff_limit
        sleep delay * BACKOFF_DELAY
        delay *= 2
        retry
      else
        STDERR.puts "Exceeded time limit"
      end
    end

    # If we are passed a block, poll on the status of this invalidation with truncated exponential backoff.
    if block_given?
      invalidation_id = doc.elements["Invalidation/Id"].text rescue nil
      poll_invalidation(invalidation_id) {|status,time| yield status, time} if invalidation_id
    end
    
    return resp
  end

  def poll_invalidation(invalidation_id)
    start = Time.now
    delay = 1
    loop do
      doc = REXML::Document.new get_invalidation_detail_xml(invalidation_id)
      status = doc.elements["Invalidation/Status"].text
      yield status, Time.now - start
      break if status != "InProgress"
      unless delay >= @backoff_limit
        sleep delay * BACKOFF_DELAY
        delay *= 2
      else
        STDERR.puts "Exceeded time limit"
        break
      end
    end
  end

  def list(show_detail = false)
    uri = URI.parse "#{BASE_URL}#{@cf_dist_id}/invalidation"
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    resp = http.send_request 'GET', uri.path, '', headers

    doc = REXML::Document.new resp.body
    puts "MaxItems " + doc.elements["InvalidationList/MaxItems"].text + "; " + (doc.elements["InvalidationList/MaxItems"].text == "true" ? "truncated" : "not truncated")

    doc.each_element("/InvalidationList/InvalidationSummary") do |summary|
      invalidation_id = summary.elements["Id"].text
      summary_text = "ID " + invalidation_id + ": " + summary.elements["Status"].text

      if show_detail
        detail_doc = REXML::Document.new get_invalidation_detail_xml(invalidation_id)
        puts summary_text +
             "; Created at: " +
             detail_doc.elements["Invalidation/CreateTime"].text +
             '; Caller reference: "' +
             detail_doc.elements["Invalidation/InvalidationBatch/CallerReference"].text +
             '"'
        puts '  Invalidated URL paths:'
        
        puts "    " + detail_doc.elements.to_a('Invalidation/InvalidationBatch/Path').map { |path| path.text }.join(" ")
      else
        puts summary_text
      end
    end
  end

  def list_detail
    list(true)
  end

  def get_invalidation_detail_xml(invalidation_id)
    uri = URI.parse "#{BASE_URL}#{@cf_dist_id}/invalidation/#{invalidation_id}"
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    resp = http.send_request 'GET', uri.path, '', headers
    return resp.body
  end

  def xml_body(keys)
    xml = <<XML
<?xml version="1.0" encoding="UTF-8"?>
<InvalidationBatch xmlns="#{DOC_URL}">
  <Paths>
    <Quantity>#{keys.size}</Quantity>
    <Items>
      #{keys.map{|k| "<Path>#{k}</Path>" }.join("\n    ")}
    </Items>
  </Paths>
  <CallerReference>#{self.class.to_s} on #{Socket.gethostname} at #{Time.now.to_i}</CallerReference>"
</InvalidationBatch>
XML
  end
  
  def headers
    date = Time.now.strftime('%a, %d %b %Y %H:%M:%S %Z')
    digest = HMAC::SHA1.new(@aws_secret)
    digest << date
    signature = Base64.encode64(digest.digest)
    {'Date' =>  date, 'Authorization' => "AWS #{@aws_key}:#{signature}"}
  end

  class TooManyInvalidationsInProgress < StandardError ; end

end
