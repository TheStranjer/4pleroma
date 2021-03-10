require 'json'
require 'net/http'

class FourPleroma
  attr_accessor :info, :old_threads, :bearer_token, :instance, :filename, :skip_first

  def initialize(fn)
    @filename = fn
    @info = JSON.parse(File.open(filename, "r").read)
    @bearer_token = info['bearer_token']
    @instance = info['instance']
    @old_threads = []
    @skip_first = true
    @info["badwords"].collect! { |badword| badword.downcase }
  end

  def start
    puts "4pleroma bot, watching catalog: #{info['catalog_url']}"

    info["threads_touched"] ||= {}

    while true
      timestamp = Time.now.to_i

      threads = JSON.parse(Net::HTTP.get(URI(info['catalog_url'])))
      threads.collect! { |x| x["threads"] }
      threads.flatten!

      new_threads = {}

      otn = thread_numbers(old_threads)
      ntn = thread_numbers(threads)

      deleted_thread_numbers = otn - ntn

      threads.reject! { |x| deleted_thread_numbers.include?(x["no"]) }

      info["threads_touched"].reject! { |k, v| deleted_thread_numbers.include?(k) }
      info["old_threads"] = threads

      threads.each do |thread|
        thread_no = thread["no"].to_s
        next if info["threads_touched"].keys.include?(thread_no) and info["threads_touched"][thread_no] >= (thread["last_modified"]-600)
        thread_url = info['thread_url'].gsub("%%NUMBER%%", thread_no.to_s)
        puts "EXAMINING THREAD: #{thread_url}"
        begin
          posts = JSON.parse(Net::HTTP.get(URI(thread_url)))["posts"]
        rescue JSON::ParserError
          next
        end

        thread_words = posts.collect { |post| post_words(post) }.flatten.uniq
        thread_badwords = thread_words & info["badwords"]

        if thread_badwords.length > 0
          puts "\tSkipping thread for detected bad words: #{thread_badwords.to_s}"
          info["threads_touched"][thread_no] = Float::INFINITY
          next
        end

        posts.select! { |x| x["time"] >= info["threads_touched"][thread_no].to_i and x["tim"] }
        posts.each do |post|
          post_image(info['image_url'].gsub("%%TIM%%", post["tim"].to_s).gsub("%%EXT%%", post["ext"]), post)
        end

        info["threads_touched"][thread_no] = timestamp.to_i
      end

      f = File.open(filename, "w")
      f.write(JSON.pretty_generate(info))
      f.close

      puts "SLEEPING NOW"

      @skip_first = false
      sleep 60
    end
  end

  def post_words(post)
    wds = words(post["com"]) + words(post["filename"]) + words(post["sub"])
    wds.uniq
  end

  def words(text)
    text.to_s.downcase.scan(/[\w']+/)
  end

  def post_image(url, post)
    puts "\tFOUND NEW IMAGE: #{url}"
    return if @skip_first
    img = Net::HTTP.get(URI(url))

    uri = URI.parse("https://#{instance}/api/v1/media")
    header = {'Authorization': "Bearer #{bearer_token}"}

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    filename = "#{post['filename']}#{post['ext']}"
    f = File.open(filename, "w")
    f.write(img)
    f.close

    req = Net::HTTP::Post.new(uri.request_uri)
    req['Authorization'] = "Bearer #{bearer_token}"
    req.set_form({"file" => File.open(filename)}, "multipart/form-data")

    res = http.request(req)

    begin
      response = JSON.parse(res.body)
    rescue JSON::ParserError
      return
    end
    
    uri = URI.parse("https://#{@instance}/api/v1/statuses")
    header = {
      'Authorization'=> "Bearer #{bearer_token}",
      'Content-Type' => 'application/json'
    }

    req = Net::HTTP::Post.new(uri.request_uri, header)
    req.body = {
      'status'       => "#{info['content_prepend']}#{process_html(post['com'])}#{info['content_append']}",
      'source'       => '4pleroma',
      'visibility'   => 'public',
      'content_type' => 'text/html',
      'media_ids'    => [response['id']]
    }.to_json

    puts req.body

    res = http.request(req)

    File.delete(filename)
  end

  def process_html(html)
    return "" if html.nil?
    html.gsub!(/<a href="#p\d+" class="quotelink">&gt;&gt;\d+<\/a>/, "")
    html.gsub!(/^&gt;(.+)$/, "<font color='#789922'>&gt;\\1</font>")
    html
  end

  def thread_numbers(threads)
    threads.collect { |x| x["no"] }
  end
end

FourPleroma.new(ARGV.find { |x| /\.json$/i.match(x) } || "info.json").start
