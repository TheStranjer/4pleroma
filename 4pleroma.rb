require 'json'
require 'net/http'
require 'pry'
require 'colorize'

class String
  def words
    self.downcase.scan(/[\w']+/)
  end
end

class Array
  def to_unescaped_s
    "[" + collect { |el| "\"#{el.to_s}\"" }.join(', ') + "]"
  end
end

module FourPleroma
  class Catalog
    attr_accessor :threads, :schema

    def initialize(contents, schema='4chan')
      @schema = schema
      send("initialize_#{schema}", contents)
    end

    def to_h
      self.threads.collect(&:to_h)
    end

    private

    def initialize_4chan(contents)
      @threads =
        contents
        .collect { |thr| thr["threads"] }
        .flatten
        .collect { |thr| Thread.new(thr, '4chan') }
    end
  end

  class Thread
    attr_accessor :schema, :no, :posts, :last_modified

    def initialize(contents, schema='4chan')
      @schema = schema
      send("initialize_#{schema}", contents)
    end

    def words
      posts.collect(&:words).flatten if posts.class == Array
    end

    def to_h
      {
        'no'            => no,
        'last_modified' => last_modified,
        'posts'         => posts ? posts.collect(&:to_h) : []
      }
    end

    private

    def initialize_4chan(contents)
      @no = contents['no'].to_s
      @last_modified = contents['last_modified'].to_i
    end
  end

  class Post
    attr_accessor :schema, :no, :remote_filename, :name, :body, :ext, :posted_at, :filename

    def initialize(contents, schema='4chan')
      @schema = schema
      send("initialize_#{schema}", contents)
    end

    def words
      filename.words +
      name.words +
      body.words
    end

    def to_h
      {
        'no'              => no,
        'remote_filename' => remote_filename,
        'name'            => name,
        'body'            => body,
        'ext'             => ext,
        'posted_at'       => posted_at
      }
    end

    private

    def initialize_4chan(contents)
      @no = contents['no'].to_s
      @remote_filename = contents['tim'].to_s
      @name = contents['name'].to_s
      @body = contents['com'].to_s
      @ext = contents['ext'].to_s
      @posted_at = contents['time'].to_i
      @filename = contents['filename'].to_s
    end
  end

  class Main
    attr_accessor :info, :old_threads, :bearer_token, :instance, :filename, :skip_first, :name, :max_sleep_time, :visibility_listing, :schema, :queue_wait, :queue, :sensitive, :initial_wait

    def initialize(fn, info = nil)
      @filename = fn
      @info = info || JSON.parse(File.open(filename, "r").read)
      @bearer_token = info['bearer_token']
      @instance = info['instance']
      @old_threads = []
      @skip_first = true
      @info["badwords"].collect! { |badword| badword.downcase }
      @name = info['name']
      @max_sleep_time = info['max_sleep_time'] || 3600
      @visibility_listing = info['visibility_listing'] || 'public'
      @schema = info['schema'] || '4chan'
      @queue_wait = info['queue_wait'] || 600
      @queue = []
      @sensitive = info['sensitive'] || false
      @initial_wait = info['initial_wait'] || queue_wait
    end

    def start_pop_queue
      puts "WILL START POPPING #{name.cyan}'s QUEUE AT: #{Time.at(Time.now.to_i + initial_wait).strftime("%I:%M %p").yellow} (#{initial_wait.yellow}s)"
      sleep initial_wait

      while true
        queue.shuffle!
        candidate = queue.pop

        if candidate.nil?
          puts "WILL POP #{name.cyan}'s QUEUE AT: #{Time.at(Time.now.to_i + queue_wait).strftime("%I:%M %p").yellow} (#{queue_wait.yellow}s)"
          sleep queue_wait
          next
        end

        post_image(info['image_url'].gsub("%%TIM%%", candidate[:post].remote_filename).gsub("%%EXT%%", candidate[:post].ext), candidate[:post], candidate[:thread])

        puts "WILL POP #{name.cyan}'s QUEUE AT: #{Time.at(Time.now.to_i + queue_wait).strftime("%I:%M %p").yellow} (#{queue_wait.yellow}s)"
        sleep queue_wait
      end
    end

    def start_build_queue
      puts "4pleroma bot, watching catalog: #{info['catalog_url'].cyan}"

      info["threads_touched"] ||= {}

      info['based_cringe'] ||= {}

      while true
        timestamp = Time.now.to_i

        begin
          catalog = JSON.parse(Net::HTTP.get(URI(info['catalog_url'])))
        rescue Net::OpenTimeout
          next
        end
        
        catalog = Catalog.new(catalog, schema)

        otn = info['old_threads'].collect { |thr| thr['no'] }
        ntn = catalog.threads.collect { |thr| thr.no }

        dtn = otn - ntn

        deleted_elements = queue.select { |el| dtn.include?(el[:thread].no) }
        queue.reject! { |el| dtn.include?(el[:thread].no) }

        puts "Removed the following threads from #{name.cyan} due to expiration: #{dtn.red.to_unescaped_s}" if dtn.size > 0
        puts "Removed #{deleted_elements.length.red} elements from the #{name.cyan} queue" if deleted_elements.length > 0

        info['threads_touched'].select! { |k, v| ntn.include?(k.to_s) }
        info['based_cringe'].select! {|k, v| ntn.include?(k.to_s) }

        info["old_threads"] = catalog.to_h

        rate_limit_exponent = 0

        notifications.each do |notif|
          next if notif['id'].nil?
          info['last_notification_id'] = notif['id'].to_i if notif['id'].to_i > info['last_notification_id'].to_i

          next if notif['type'] != 'reblog'
          status_id = notif['status']['id']
          tno = nil
          pno = nil

          info['based_cringe'].each do |thread_no, contents|
            next if contents['posts'].nil?

            pno = contents['posts'].find { |post_no, post_contents| post_contents['pleroma_id'] == status_id }
            pno = pno.first if pno

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
          info['based_cringe'][tno]['posts'][pno]['based'].push(notif['account']['acct'] || notif['account']['fqn'])
          info['based_cringe'][tno]['posts'][pno]['based'].uniq!

          thread = Thread.new(info['old_threads'].find { |thr| thr['no'].to_i == tno.to_i })

          based = how_based(thread)
          cringe = how_cringe(thread)
          puts "REBLOG #{name.cyan} - #{tno.cyan}, Based: #{based.green}, Cringe: #{cringe.red}"

          next if based < cringe

          options = queue.select {|x| x[:thread].no == tno.to_s }

          next if options.length == 0

          options.shuffle!
          candidate = options.pop

          puts "FAST TRACKING QUEUED IMAGE FROM #{name.cyan} FOR THREAD #{thread.no.green} DUE TO USER OPT-IN"
          post_image(info['image_url'].gsub("%%TIM%%", candidate[:post].remote_filename).gsub("%%EXT%%", candidate[:post].ext), candidate[:post], candidate[:thread])
        end

        catalog.threads.each do |thread|
          next if info["threads_touched"].keys.include?(thread.no) and info["threads_touched"][thread.no] >= (thread.last_modified - info['janny_lag'])
          based = how_based(thread)
          cringe = how_cringe(thread)
          next if cringe > based
          thread_url = info['thread_url'].gsub("%%NUMBER%%", thread.no)
          puts "EXAMINING THREAD: #{name.cyan} - #{thread.no.cyan}"
          begin
            thread.posts = JSON.parse(Net::HTTP.get(URI(thread_url)))["posts"].collect { |p| Post.new(p, schema) }
          rescue JSON::ParserError
            next
          end

          thread_words = thread.words.uniq
          thread_badwords = thread_words.select { |tw| info["badwords"].any? { |bw| bw == tw } || info["badregex"].any? { |br| %r{#{br}}i.match(tw) } }

          if thread_badwords.length > 0
            puts "\tSkipping #{name.cyan} - #{thread.no.cyan} for detected bad words: #{thread_badwords.red.to_unescaped_s}"
            info["threads_touched"][thread.no] = Float::INFINITY
            next
          end
         
          thread.posts.select { |p| p.posted_at >= info["threads_touched"][thread.no].to_i and p.remote_filename.length > 0 }.each do |p|
            based = how_based(thread)
            cringe = how_cringe(thread)
            if based > 0 and based >= cringe
              puts "FAST TRACKING NEWLY-DISCOVERED IMAGE FOR #{name.cyan} FOR THREAD #{thread.no.green} DUE TO USER OPT-IN"
              post_image(info['image_url'].gsub("%%TIM%%", p.remote_filename).gsub("%%EXT%%", p.ext), p, thread)
            else
              queue.push({
                :post => p,
                :thread => thread
              })

              puts "ADDED #{name.cyan} - #{thread.no.cyan} - #{p.no.cyan} TO QUEUE, BRINGING ITS SIZE TO #{queue.length.cyan}"
            end
          end

          info["threads_touched"][thread.no] = timestamp.to_i
        end

        new_info = info
        new_info["threads_touched"].select { |k,v| v == Float::INFINITY }.keys.each { |k| new_info["threads_touched"][k] = Time.now.to_i * 2 }

        f = File.open(filename, "w")
        f.write(JSON.pretty_generate(new_info))
        f.close

        @skip_first = false
        sleep 60
      end
    end

    def post_words(post)
      wds = words(post["com"]) + words(post["filename"]) + words(post["sub"])
      wds.uniq
    end

    def post_image(url, post, thread)
      return if @skip_first
      res = Net::HTTP.get_response(URI(url))

      if res.code != '200'
        puts "ERROR'D OUT ON #{name.red} - #{thread.no.red} - #{post.no.red}"
        return
      end

      img = res.body

      uri = URI.parse("https://#{instance}/api/v1/media")
      header = {'Authorization': "Bearer #{bearer_token}"}

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      filename = "#{post.filename}#{post.ext}"

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

      tno = thread.no
      pno = post.no
      info['based_cringe'] = {} if info['based_cringe'].nil?
      info['based_cringe'][tno] = { 'posts' => {} } if info['based_cringe'][tno].nil?
      info['based_cringe'][tno]['posts'][pno] = {} if info['based_cringe'][tno]['posts'][pno].nil?

      mentions = info['based_cringe'][tno]['posts'].collect { |post_no, post| post['based'] ? post['based'] : [] }.flatten
      mentions.uniq!
      mentions.collect! { |mention| "@#{mention}" }

      req = Net::HTTP::Post.new(uri.request_uri, header)
      req.body = {
        'status'       => "#{mentions.join(' ')}\n#{info['content_prepend']}#{process_html(post.body)}#{info['content_append']}".strip,
        'source'       => '4pleroma',
        'visibility'   => visibility_listing,
        'sensitive'    => sensitive,
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

      info['based_cringe'][tno]['posts'][pno]['pleroma_id'] = json_res['id']

      queue.reject! { |el| el[:post].no == post.no and el[:thread].no == thread.no }

      puts "NEW IMAGE ON #{name.cyan} - #{tno.cyan}: #{filename.cyan}, with based rating now at #{how_based(thread).green} and cringe rating now at #{how_cringe(thread).red}"
    end

    def process_html(html)
      return "" if html.nil?
      html.gsub(/<a href=".+" class="quotelink">&gt;&gt;\d+<\/a>/, "")
          .gsub(/^&gt;(.+)$/, "<font color='#789922'>&gt;\\1</font>")
    end

    def thread_numbers(threads)
      threads.collect { |x| x["no"] }
    end

    def notifications
      begin
        url = "https://#{instance}/api/v1/notifications?with_muted=true&limit=20"
        url += "&since_id=#{info['last_notification_id']}" if info['last_notification_id']

        uri = URI.parse(url)
        header = {'Authorization': "Bearer #{bearer_token}"}

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true

        req = Net::HTTP::Get.new(uri.request_uri, header)

        res = http.request(req)

        JSON.parse(res.body)
      rescue
        []
      end
    end

    def how_based(thread)
      return 0 if info['based_cringe'][thread.no].nil?
      info['based_cringe'][thread.no]['posts'].sum { |no, post| post['based'].nil? ? 0 : post['based'].length }
    end

    def how_cringe(thread)
      return 0 if info['based_cringe'][thread.no].nil?
      info['based_cringe'][thread.no]['posts'].length
    end
  end
end

config_files = ARGV.select { |x| /\.json$/i.match(x) }

infos = {}
badwords = []
badregex = []
threads = {}

config_files.each do |cf|
    infos[cf] = JSON.parse(File.open(cf, "r").read)
    badwords += infos[cf]["badwords"] if infos[cf]["badwords"].class == Array
    badregex += infos[cf]["badregex"] if infos[cf]["badregex"].class == Array
end

badwords.uniq!
badregex.uniq!

config_files.each do |cf|
  infos[cf]["badwords"] = badwords unless infos[cf]["isolated_badwords"] == true
  infos[cf]["badregex"] = badregex unless infos[cf]["isolated_badregex"] == true
  four_pleroma = FourPleroma::Main.new(cf, infos[cf])
  threads["#{cf} build_queue"] = Thread.new do
    four_pleroma.start_build_queue
  end
  threads["#{cf} pop_queue"] = Thread.new do
    four_pleroma.start_pop_queue
  end
end

threads.each { |cf,thr| thr.join }

