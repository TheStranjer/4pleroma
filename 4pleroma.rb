require 'json'
require 'net/http'
require 'pry'
require 'colorize'
require 'syndesmos'

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
    COMMANDS = {
      /untag/i => "untag",
      /notag/i => "notag",
      /tag/i   => "tag"
    }

    attr_accessor :info, :old_threads, :bearer_token, :instance, :filename, :skip_first, :name, :max_sleep_time, :visibility_listing, :schema, :queue_wait, :queue, :sensitive, :initial_wait

    attr_accessor :client

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

      @client = Syndesmos.new(bearer_token: bearer_token, instance: instance)

      raise "Invalid credentials" unless client.valid_credentials?

      @client.add_hook(:notification, self, :new_notification)
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

    def cmd_tag(notif)
      acct = notif['account']['acct'] || notif['acct']['fqn']
      info['notag'] ||= []
      deleted = info['notag'].delete(acct)

      client.statuses({
        "status"         => "@#{acct} " + (deleted ? "You will now be tagged again by this bot" : "You are already taggable by this bot"),
        "visibility"     => "direct",
        "in_reply_to_id" => notif['status']['id']
      })

      save_info(info)
    end

    def cmd_notag(notif)
      acct = notif['account']['acct'] || notif['acct']['fqn']
      info['notag'] ||= []
      info['notag'].push(acct)
      info['notag'].uniq!

      client.statuses({
        "status"         => "@#{acct} You won't be tagged by this bot in the future",
        "visibility"     => "direct",
        "in_reply_to_id" => notif['status']['id']
      })

      save_info(info)
    end

    def cmd_untag(notif)
      reply_to_id = notif['status']['in_reply_to_id']
      acct = notif['account']['acct'] || notif['acct']['fqn']

      if reply_to_id.nil?
        client.statuses({
          "status"         => "@#{acct} I can't untag you from a thread unless you respond to the image post from that thread",
          "visibility"     => "direct",
          "in_reply_to_id" => notif['status']['id']
        })

        return
      end

      tno = info['based_cringe'].keys.find { |tno| info['based_cringe'][tno]['posts'].any? { |pno, post| post['pleroma_id'] == reply_to_id } }
      info['based_cringe'][tno] ||= {}
      info['based_cringe'][tno]['untagged'] ||= []
      info['based_cringe'][tno]['untagged'].push(acct)
      info['based_cringe'][tno]['untagged'].uniq!

      client.statuses({
        "status"         => "@#{acct} You've been untagged from this thread and should not receive any more tags about it",
        "visibility"     => "direct",
        "in_reply_to_id" => notif['status']['id']
      })

      save_info(info)
    end

    def new_reblog(notif)
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

      return if tno.nil?

      acct = notif['account']['acct'] || notif['account']['fqn']

      info['based_cringe'][tno] = {} if info['based_cringe'][tno].nil?
      info['based_cringe'][tno]['posts'] = {} if info['based_cringe'][tno]['posts'].nil?
      info['based_cringe'][tno]['posts'][pno] = {} if info['based_cringe'][tno]['posts'][pno].nil?
      info['based_cringe'][tno]['posts'][pno]['based'] = [] if info['based_cringe'][tno]['posts'][pno]['based'].nil?
      info['based_cringe'][tno]['posts'][pno]['based'].push(acct)
      info['based_cringe'][tno]['posts'][pno]['based'].uniq!

      if /#(nobot|notag)/i.match(notif['account'].to_s)
        info['notag'] ||= []
        info['notag'].push(acct)
      end

      thread = Thread.new(info['old_threads'].find { |thr| thr['no'].to_i == tno.to_i })

      based = how_based(thread)
      cringe = how_cringe(thread)
      puts "REBLOG #{name.cyan} - #{tno.cyan}, Based: #{based.green}, Cringe: #{cringe.red}"

      return if based < cringe

      options = queue.select {|x| x[:thread].no == tno.to_s }

      return if options.length == 0

      options.shuffle!
      candidate = options.pop

      puts "FAST TRACKING QUEUED IMAGE FROM #{name.cyan} FOR THREAD #{thread.no.green} DUE TO USER OPT-IN"
      post_image(info['image_url'].gsub("%%TIM%%", candidate[:post].remote_filename).gsub("%%EXT%%", candidate[:post].ext), candidate[:post], candidate[:thread])

      queue.reject! { |element| candidate[:post].no == element[:post].no and candidate[:thread].no == element[:thread].no }
    end

    def new_mention(notif)
      COMMANDS.select { |regex, cmd| regex.match(notif['status']['content']) }.each do |cmd|
        send("cmd_#{cmd[1]}".to_sym, notif)
      end
    end

    def new_notification(notif)
      return if notif['id'].nil?
      info['last_notification_id'] = notif['id'].to_i if notif['id'].to_i > info['last_notification_id'].to_i

      meth = "new_#{notif['type']}".to_sym

      send(meth, notif) if self.respond_to?(meth)
    end

    def start_build_queue
      puts "4pleroma bot, watching catalog: #{info['catalog_url'].cyan}"

      info["threads_touched"] ||= {}

      info['based_cringe'] ||= {}

      while true
        timestamp = Time.now.to_i

        old_queue_posts = queue.collect { |p| p[:post].no }

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

        info['threads_touched'].select! { |k, v| ntn.include?(k.to_s) }
        info['based_cringe'].select! {|k, v| ntn.include?(k.to_s) }

        info["old_threads"] = catalog.to_h

        rate_limit_exponent = 0

        catalog.threads.each do |thread|
          based = how_based(thread)
          cringe = how_cringe(thread)
          next if cringe > based
          candidates = queue.select { |el| el[:thread].no == thread.no }
          el = candidates.sample
          if based > 0 and el
            puts "FAST TRACKING NEWLY-DISCOVERED IMAGE FOR #{name.cyan} FOR THREAD #{el[:thread].no.green} DUE TO USER OPT-IN"

            post_image(info['image_url'].gsub("%%TIM%%", el[:post].remote_filename).gsub("%%EXT%%", el[:post].ext), el[:post], el[:thread])
            queue.reject! { |element| el[:post].no == element[:post].no and el[:thread].no == element[:thread].no }
          end

          next if info["threads_touched"].keys.include?(thread.no) and info["threads_touched"][thread.no] >= (thread.last_modified - info['janny_lag'])
          thread_url = info['thread_url'].gsub("%%NUMBER%%", thread.no)
          begin
            thread.posts = JSON.parse(Net::HTTP.get(URI(thread_url)))["posts"].collect { |p| Post.new(p, schema) }
          rescue JSON::ParserError
            next
          end

          thread_words = thread.words.uniq
          thread_badwords = thread_words.select { |tw| info["badwords"].any? { |bw| bw == tw } || info["badregex"].any? { |br| %r{#{br}}i.match(tw) } }

          if thread_badwords.length > 0
            puts "Skipping #{name.cyan} - #{thread.no.cyan} for detected bad words: #{thread_badwords.red.to_unescaped_s}"
            info["threads_touched"][thread.no] = Float::INFINITY
            next
          end
          
          thread.posts.select { |p| p.posted_at >= info["threads_touched"][thread.no].to_i and p.remote_filename.length > 0 }.each do |p|
            queue.push({
              :post => p,
              :thread => thread
            })
          end

          info["threads_touched"][thread.no] = timestamp.to_i
        end

        new_queue_posts = queue.collect { |p| p[:post].no }

        messages = []
        new_post_count = (new_queue_posts - old_queue_posts).length
        removed_post_count = (old_queue_posts - new_queue_posts).length
        messages.push("ADDED #{new_post_count.green} TO") if new_post_count > 0
        messages.push("REMOVED #{removed_post_count.red} FROM") if removed_post_count > 0

        puts "#{messages.join(' AND ')} THE #{name.cyan} QUEUE, BRINGING THE TOTAL TO #{queue.length.send(removed_post_count > new_post_count ? :red : (new_post_count > removed_post_count ? :green : :cyan))}" if messages.length > 0

        new_info = info
        new_info["threads_touched"].select { |k,v| v == Float::INFINITY }.keys.each { |k| new_info["threads_touched"][k] = Time.now.to_i * 2 }

        save_info(new_info)

        @skip_first = false
        sleep 60
      end
    end

    def save_info(new_info)
      f = File.open(filename, "w")
      f.write(JSON.pretty_generate(new_info))
      f.close
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

      filename = "#{post.filename}#{post.ext}"

      f = File.open(filename, "w")
      f.write(img)
      f.close

      begin
        response = client.media(filename)
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
      info['based_cringe'][tno]['untagged'] ||= []
      info['based_cringe'][tno]['posts'][pno] = {} if info['based_cringe'][tno]['posts'][pno].nil?

      info['notag'] ||= []

      mentions = info['based_cringe'][tno]['posts'].collect { |post_no, post| post['based'] ? post['based'] : [] }.flatten
      mentions.uniq!

      mentions.reject! { |mention| info['based_cringe'][tno]['untagged'].include?(mention) }
      mentions.reject! { |mention| info['notag'].include?(mention) }
      mentions.collect! { |mention| "@#{mention}" }

      begin
        json_res = client.statuses({
        'status'       => "#{mentions.join(' ')}\n#{info['content_prepend']}#{process_html(post.body)}#{info['content_append']}".strip,
        'source'       => '4pleroma',
        'visibility'   => visibility_listing,
        'sensitive'    => sensitive,
        'content_type' => 'text/html',
        'media_ids'    => [response['id']]
      })
      rescue JSON::ParserError
        return
      end

      File.delete(filename)

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

