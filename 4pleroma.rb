require 'json'
require 'net/http'
require 'pry'
require 'colorize'
require 'syndesmos'

class String
  def words
    self.downcase.scan(/[\w']+/)
  end

  def filesystem_sanitize
    gsub('/', '_')
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
      /[^o]tag/i   => "tag"
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

      @info['thread_ops'] ||= {}

      @info['media_ids'] ||= {}

      @client = Syndesmos.new(bearer_token: bearer_token, instance: instance)

      raise "Invalid credentials" unless client.valid_credentials?

      @client.add_hook(:notification, self, :new_notification)
    end

    def start_pop_queue
      delay_pop

      while true
        regex = /^\.\/files\/\w+\/(\d+)\/(.+)$/
        filename = Dir["./files/#{name.filesystem_sanitize}/**/*"].select { |fn| regex.match(fn) and !info['media_ids'].include?(fn) }.sample

        m = regex.match(filename)
        candidate = queue.reject { |q| q.nil? }.find { |c|
          c[:thread].no == m[1] and
          c[:post].no == m[2] }

        json_res = post_image(filename, candidate ? candidate[:post].body : "")
        puts "NEW IMAGE ON #{name.cyan}: #{filename.cyan}"
        queue.reject! { |el| el[:post].no == m[2] and el[:thread].no == m[1] }
        
        if json_res.nil?
          delay_pop
          next
        end

        info['based_cringe'][m[1]] ||= {}
        info['based_cringe'][m[1]]['posts'] ||= {}
        info['based_cringe'][m[1]]['posts'][m[2]] ||= {}
        info['based_cringe'][m[1]]['posts'][m[2]]['pleroma_id'] = json_res['id']

        delay_pop
      end
    end

    def delay_pop
      begin
        popping_time = Time.at(Time.now.to_i + queue_wait).strftime("%I:%M %p %Z")
        client.update_credentials({"fields_attributes": [ { "name": "Bot Author", "value": "@NEETzsche@iddqd.social" }, {"name": "Next Post", "value": popping_time} ]})
        puts "WILL POP #{name.cyan}'s QUEUE AT: #{popping_time.yellow} (#{queue_wait.yellow}s)"
        sleep queue_wait
      rescue
        nil
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

    def new_favourite(notif)
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
      info['based_cringe'][tno]['posts'][pno]['fav'] = [] if info['based_cringe'][tno]['posts'][pno]['fav'].nil?
      info['based_cringe'][tno]['posts'][pno]['fav'].push(acct)
      info['based_cringe'][tno]['posts'][pno]['fav'].uniq!

      if /#(nobot|notag)/i.match(notif['account'].to_s)
        info['notag'] ||= []
        info['notag'].push(acct)
      end

      save_info(info)

      notify_opt_out(acct)
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

      save_info(info)


      notify_opt_out(acct)

      thread = Thread.new(info['old_threads'].find { |thr| thr['no'].to_i == tno.to_i })

      based = how_based(thread)
      cringe = how_cringe(thread)
      puts "REBLOG #{name.cyan} - #{tno.cyan}, Based: #{based.green}, Cringe: #{cringe.red}"

      return if based < cringe

      options = queue.select {|x| x[:thread].no == tno.to_s }

      return if options.length == 0

      options.shuffle!
      candidate = options.pop

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

    def get_directory(tno)
      "./files/#{name.filesystem_sanitize}/#{tno}/"
    end

    def start_build_queue
      puts "4pleroma bot, watching catalog: #{info['catalog_url'].cyan}"

      info["threads_touched"] ||= {}

      info['based_cringe'] ||= {}

      while true
        queue_start = Dir["./files/#{name.filesystem_sanitize}/**/*"].length

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

        dump_threads = dtn.select { |tno| info['based_cringe'][tno] and info['based_cringe'][tno]['posts'] and info['based_cringe'][tno]['posts'].any? { |pno, post| (post['based'] and post['based'].length > 0) or (post['fav'] and post['fav'].length > 0) } }.each do |tno|
          mentions = info['based_cringe'][tno]['posts'].collect { |post_no, post| post['based'] ? post['based'] : [] }.flatten
          directory = get_directory(tno)

          files = Dir["#{directory}/**/*"]
          next if files.length == 0

          puts "DUMPING #{name.cyan} THREAD: #{tno.green} with #{files.length.yellow} posts and with the following mentions: #{mentions.cyan.to_unescaped_s}"
          next if mentions.length == 0

          info['based_cringe'][tno]['untagged'] ||= []
          mentions.reject! { |mention|  info['based_cringe'][tno]['untagged'].include?(mention) }
          mentions.reject! { |mention| info['notag'].include?(mention) }
          mentions.collect! { |mention| "@#{mention}" }

          mentions.uniq!

          post_image(files, "\nThis is an image dump of #{name} thread #{tno}:\n#{info['thread_ops'][tno]}\n\n#{mentions.join(' ')}".gsub("\n\n\n", " "))
        end

        Dir["./files/#{name.filesystem_sanitize}/*"].each do |fn|
          m = /^\.\/files\/#{name.filesystem_sanitize}\/(\d+)$/i.match(fn)
          next if m.nil?
          tno = m[1]
          next if ntn.include?(tno)
          directory = get_directory(tno)
          FileUtils.remove_dir(directory) if File.directory?(directory)
        end

        deleted_elements = queue.select { |el| dtn.include?(el[:thread].no) }
        queue.reject! { |el| dtn.include?(el[:thread].no) }

        info['thread_ops'].reject! { |k| dtn.include?(k) }

        puts "Removed the following threads from #{name.cyan} due to expiration: #{dtn.red.to_unescaped_s}" if dtn.size > 0

        info['threads_touched'].select! { |k, v| ntn.include?(k.to_s) }
        info['based_cringe'].select! {|k, v| ntn.include?(k.to_s) }

        info["old_threads"] = catalog.to_h

        rate_limit_exponent = 0

        catalog.threads.each do |thread|

          based = how_based(thread)
          cringe = how_cringe(thread)
          next if cringe > based
          next if info["threads_touched"].keys.include?(thread.no) and info["threads_touched"][thread.no] >= (thread.last_modified - info['janny_lag'])
          thread_url = info['thread_url'].gsub("%%NUMBER%%", thread.no)
          begin
            thread.posts = JSON.parse(Net::HTTP.get(URI(thread_url)))["posts"].collect { |p| Post.new(p, schema) }
          rescue JSON::ParserError
            next
          end

          info['thread_ops'][thread.no] = thread.posts.first.body if thread.posts

          thread_words = thread.words.uniq
          thread_badwords = thread_words.select { |tw| info["badwords"].any? { |bw| bw == tw } || info["badregex"].any? { |br| %r{#{br}}i.match(tw) } }

          if thread_badwords.length > 0
            puts "Skipping #{name.cyan} - #{thread.no.cyan} for detected bad words: #{thread_badwords.red.to_unescaped_s}"
            info["threads_touched"][thread.no] = Float::INFINITY
            next
          end
          
          thread.posts.select { |p| p.posted_at >= info["threads_touched"][thread.no].to_i and p.remote_filename.length > 0 }.each do |p|
            begin
              directory = get_directory(thread.no)
              FileUtils.mkdir_p(directory)
              filename = "#{directory}#{p.filename}#{p.ext}"

              url = info['image_url'].gsub("%%TIM%%", p.remote_filename).gsub("%%EXT%%", p.ext)
              img = Net::HTTP.get_response(URI(url)).body
              f = File.open(filename, "w")
              f.write(img)
              f.close

              queue.push({
                :post => p,
                :thread => thread,
                :filename => filename
              })
            rescue => e
              puts "Could not save file, yielding error of type #{e.class.red} with message #{e.message.red}"
            end
          end

          info["threads_touched"][thread.no] = timestamp.to_i
        end

        new_queue_posts = queue.collect { |p| p[:post].no }

        new_info = info
        new_info["threads_touched"].select { |k,v| v == Float::INFINITY }.keys.each { |k| new_info["threads_touched"][k] = Time.now.to_i * 2 }

        save_info(new_info)

        @skip_first = false

        queue_end = Dir["./files/#{name.filesystem_sanitize}/**/*"].length

        if queue_end > queue_start
          puts "ADDED #{(queue_end - queue_start).green} NEW IMAGES TO #{name.cyan}, BRINGING THE TOTAL TO #{queue_end.green}"
        elsif queue_end < queue_start
          puts "REMOVED #{(queue_start - queue_end).red} OLD IMAGES TO #{name.cyan}, BRINGING THE TOTAL TO #{queue_end.red}"
        end

        info['media_ids'].select! { |fn, id| Dir["./files/**/*"].include?(fn) }

        sleep 60
      end
    end

    def save_info(new_info)
      f = File.open(filename, "w")
      f.write(JSON.pretty_generate(new_info))
      f.close
    end

    def notify_opt_out(user, message="You reblogged or favorited a post I made. That post came from a thread on #{name}. When the thread dies, all of the images collected from it will be uploaded in a big dump post. You will, by default, be tagged in that dump. If you don't want to be tagged in that dump, reply to the image post including the word 'untag', and if you don't want to ever be tagged in posts by me respond with 'notag' instead.")
      info['notified'] ||= []
      info['notag'] ||= []
      return if info['notified'].include?(user) or info['notag'].include?(user)
      info['notified'].push(user)

      json_res = client.statuses({
        'status'       => "@#{user} #{message}",
        'source'       => '4pleroma',
        'visibility'   => "direct",
        'sensitive'    => sensitive,
        'content_type' => 'text/html'
      })
    end

    def post_words(post)
      wds = words(post["com"]) + words(post["filename"]) + words(post["sub"])
      wds.uniq
    end

    def post_image(filename, message="")
      return if @skip_first
      filename = (filename.class == Array ? filename : [filename])
      begin
        new_media_ideas = {}
        media_ids = filename.collect { |fn| new_media_ideas[fn] = info['media_ids'][fn] || client.media(fn)['id'] }
        info['media_ids'].merge(new_media_ideas)
      rescue JSON::ParserError
        return
      end
      
      uri = URI.parse("https://#{@instance}/api/v1/statuses")
      header = {
        'Authorization'=> "Bearer #{bearer_token}",
        'Content-Type' => 'application/json'
      }

      begin
        client.statuses({
          'status'       => "#{info['content_prepend']}#{process_html(message)}#{info['content_append']}".strip,
          'source'       => '4pleroma',
          'visibility'   => visibility_listing,
          'sensitive'    => sensitive,
          'content_type' => 'text/html',
          'media_ids'    => media_ids
        })
      rescue
        nil
      end
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

