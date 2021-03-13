require 'json'
require 'net/http'
require 'pry'

class FourPleroma
  attr_accessor :info, :old_threads, :bearer_token, :instance, :filename, :skip_first, :name

  def initialize(fn, info = nil)
    @filename = fn
    @info = info || JSON.parse(File.open(filename, "r").read)
    @bearer_token = info['bearer_token']
    @instance = info['instance']
    @old_threads = []
    @skip_first = true
    @info["badwords"].collect! { |badword| badword.downcase }
    @name = info['name']
  end

  def start
    puts "4pleroma bot, watching catalog: #{info['catalog_url']}"

    info["threads_touched"] ||= {}

    info['based_cringe'] ||= {}

    while true
      timestamp = Time.now.to_i

      threads = JSON.parse(Net::HTTP.get(URI(info['catalog_url'])))
      threads.collect! { |x| x["threads"] }
      threads.flatten!

      otn = thread_numbers(threads)
      ntn = thread_numbers(threads)

      dtn = otn - ntn

      puts "Removed the following threads from #{name} due to expiration: #{dtn}" if dtn.size > 0

      info['threads_touched'].select! { |k, v| ntn.include?(k.to_i) }
      info['based_cringe'].select! {|k, v| ntn.include?(k.to_i) }

      info["old_threads"] = threads

      rate_limit_exponent = 0

      notifications.each do |notif|
        info['last_notification_id'] = notif['id'].to_i if notif['id'].to_i > info['last_notification_id'].to_i

        next if notif['type'] != 'reblog'
        status_id = notif['status']['id']
        tno = nil
        pno = nil

        info['based_cringe'].each do |thread_no, contents|
          next if contents['posts'].nil?

          pno = contents['posts'].find { |post_no, post_contents| post_contents['pleroma_id'] == status_id }
          pno = pno.first if pno
          puts "Found PNO: #{pno}" if pno

          if pno
            tno = thread_no
            break
          end
        end

        next if tno.nil?

        info['based_cringe'][tno] = {} if info['based_cringe'][tno].nil?
        info['based_cringe'][tno]['posts'] = {} if info['based_cringe'][tno]['posts'].nil?
        info['based_cringe'][tno]['posts'][pno] = {} if info['based_cringe'][tno]['posts'][pno].nil?
        info['based_cringe'][tno]['posts'][pno]['based'] = [] if info['based_cringe'][tno]['posts'][pno]['based'].nil?
        info['based_cringe'][tno]['posts'][pno]['based'].push(notif['account']['fqn'])
        info['based_cringe'][tno]['posts'][pno]['based'].uniq!

        thread = info['old_threads'].find { |thr| thr['no'].to_i == tno.to_i }

        puts "Got a reblog for #{tno}, making its based level #{how_based(thread)} and its gay level #{how_cringe(thread)}"
      end

      threads.each do |thread|
        thread_no = thread["no"].to_s
        next if info["threads_touched"].keys.include?(thread_no) and info["threads_touched"][thread_no] >= (thread['last_modified'] - info['janny_lag'])
        based = how_based(thread)
        cringe = how_cringe(thread)
        if cringe > based
          puts "Skipping #{name} - #{thread_no} for not being cool enough: #{based} < #{cringe}"
          next
        end
        thread_url = info['thread_url'].gsub("%%NUMBER%%", thread_no.to_s)
        puts "EXAMINING THREAD: #{thread_url}; #{based} >= #{cringe}"
        begin
          posts = JSON.parse(Net::HTTP.get(URI(thread_url)))["posts"]
        rescue JSON::ParserError
          next
        end

        thread_words = posts.collect { |post| post_words(post) }.flatten.uniq
        thread_badwords = thread_words & info["badwords"]

        if thread_badwords.length > 0
          puts "\tSkipping #{name} - #{thread_no} for detected bad words: #{thread_badwords.to_s}"
          info["threads_touched"][thread_no] = Float::INFINITY
          next
        end

        posts.select! { |x| x["time"] >= info["threads_touched"][thread_no].to_i and x["tim"] }
        posts.each do |post|
          post_image(info['image_url'].gsub("%%TIM%%", post["tim"].to_s).gsub("%%EXT%%", post["ext"]), post, thread)
        end

        info["threads_touched"][thread_no] = timestamp.to_i
      end

      new_info = info
      new_info["threads_touched"].select { |k,v| v == Float::INFINITY }.keys.each { |k| new_info["threads_touched"][k] = Time.now.to_i * 2 }

      f = File.open(filename, "w")
      f.write(JSON.pretty_generate(new_info))
      f.close

      puts "SLEEPING NOW: #{name}"

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

  def post_image(url, post, thread)
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

    res = http.request(req)

    File.delete(filename)

    begin
      json_res = JSON.parse(res.body)
    rescue JSON::ParserError
      return
    end

    tno = thread['no'].to_s
    pno = post['no'].to_s
    info['based_cringe'] = {} if info['based_cringe'].nil?
    info['based_cringe'][tno] = { 'posts' => {} } if info['based_cringe'][tno].nil?
    info['based_cringe'][tno]['posts'][pno] = { 'pleroma_id' => json_res['id'] } if info['based_cringe'][tno]['posts'][pno].nil?

    puts "NEW IMAGE ON #{name} - #{tno}: #{filename}, with based rating now at #{how_based(thread)} and cringe rating now at #{how_cringe(thread)}"
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

  def notifications
    url = "https://#{instance}/api/v1/notifications?with_muted=true&limit=20"
    url += "&since_id=#{info['last_notification_id']}" if info['last_notification_id']

    uri = URI.parse(url)
    header = {'Authorization': "Bearer #{bearer_token}"}

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    req = Net::HTTP::Get.new(uri.request_uri, header)

    res = http.request(req)

    JSON.parse(res.body)
  end

  def how_based(thread, start=0)
    tno = thread['no'].to_s
    return start if info['based_cringe'][tno].nil?
    info['based_cringe'][tno]['posts'].sum { |no, post| post['based'].nil? ? 0 : post['based'].length } + start
  end

  def how_cringe(thread, start=0)
    tno = thread['no'].to_s
    return start if info['based_cringe'][tno].nil?
    info['based_cringe'][tno]['posts'].length + start
  end
end

config_files = ARGV.select { |x| /\.json$/i.match(x) }

infos = {}
badwords = []
threads = {}

config_files.each do |cf|
    infos[cf] = JSON.parse(File.open(cf, "r").read)
    badwords += infos[cf]["badwords"] if infos[cf]["badwords"].class == Array
end

badwords.uniq!

config_files.each do |cf|
  infos[cf]["badwords"] = badwords
  threads[cf] = Thread.new do
    FourPleroma.new(cf, infos[cf]).start
  end
end

threads.each { |cf,thr| thr.join }

