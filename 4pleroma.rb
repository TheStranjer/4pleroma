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
  SECONDS_PER_DAY = 86400
  TIME_FORMAT_RANGES = {
    (..SECONDS_PER_DAY)                      => "%I:%M %p %Z",
    ((SECONDS_PER_DAY)..(SECONDS_PER_DAY*7)) => "%A, %I:%M %p %Z",
    ((SECONDS_PER_DAY*7)..)                  => "%A, %B %-d, %Y %I:%M %p %Z"
  }

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
      /notag/i => "notag",
      /[^o]tag/i   => "tag"
    }

    attr_accessor :info, :bearer_token, :instance, :filename, :skip_first, :name, :max_sleep_time, :visibility_listing, :schema, :queue, :sensitive, :oldest_post_time, :carried_over_dumps, :media_ids_mutex

    attr_accessor :client

    def initialize(fn, info = nil)
      @filename = fn
      @info = info || JSON.parse(File.open(filename, "r").read)
      @bearer_token = info['bearer_token']
      @instance = info['instance']
      @skip_first = true
      @info["badwords"].collect! { |badword| badword.downcase }
      @name = info['name']
      @max_sleep_time = info['max_sleep_time'] || 3600
      @visibility_listing = info['visibility_listing'] || 'public'
      @schema = info['schema'] || '4chan'
      @queue = []
      @sensitive = info['sensitive'] || false

      @info['thread_ops'] ||= {}

      @info['media_ids'] ||= {}

      @client = Syndesmos.new(bearer_token: bearer_token, instance: instance)

      raise "Invalid credentials for #{name}" unless client.valid_credentials?

      @client.add_hook(:notification, self, :new_notification)

      @oldest_post_time = {}
      info['carried_over_dumps'] ||= 0
      info['no_reacts'] ||= 1.00
      info['old_threads'] = {} if info['old_threads'].class != Hash
      info['based_cringe'].reject! {|k,v| /^\d+$/.match(k) }

      info['threads_touched'] = {} if ENV['FORCE_CLEAR']

      @media_ids_mutex = Mutex.new

      save_info info
    end

    def start_pop_queue
      delay_pop

      while true
        regex = /^\.\/files\/(\w+)\/(\d+)\/(.+)$/
        filename = info['targets'].collect { |t| t['directory'] }.collect { |t| Dir["./files/#{t.filesystem_sanitize}/**/*"].select { |fn| regex.match(fn) and media_ids_mutex.synchronize { !info['media_ids'].include?(fn) } } }.flatten.sample

        m = regex.match(filename)
        if m.nil?
          delay_pop
          next
        end
        candidate = queue.reject { |q| q.nil? }.find { |c|
          c[:thread].no == m[2] and
          c[:post].no == m[3] }

        json_res = post_image(filename, candidate ? candidate[:post].body : "")
        puts "NEW IMAGE ON #{name.cyan}: #{filename.green}"
        queue.reject! { |el| el[:post].no == m[3] and el[:thread].no == m[2] }
        
        info['no_reacts'] += 1.00

        if json_res.nil?
          delay_pop
          next
        end

        info['based_cringe'][m[1]] ||= {}
        info['based_cringe'][m[1]][m[2]] ||= {}
        info['based_cringe'][m[1]][m[2]]['posts'] ||= {}
        info['based_cringe'][m[1]][m[2]]['posts'][m[3]] ||= {}
        info['based_cringe'][m[1]][m[2]]['posts'][m[3]]['pleroma_id'] = json_res['id']

        delay_pop
      end
    end

    def delay_pop
      begin
        queue_wait = calc_wait
        info['next_post'] = Time.now.to_i + queue_wait
        popping_time = Time.at(info['next_post']).strftime(time_format)
        client.update_credentials({"fields_attributes": [ { "name": "Bot Author", "value": "@NEETzsche@iddqd.social" }, {"name": "Next Post", "value": popping_time}, {"name": "Posts Since React", "value": info['no_reacts'].to_i.to_s} ]})
        puts "WILL POP #{name.cyan}'s QUEUE AT: #{popping_time.yellow} (#{queue_wait.yellow}s) (number of posts without reacts: #{info['no_reacts'].to_i.red})"
        sleep queue_wait
      rescue => e
        puts "FAILED TO DELAY POP FOR ERROR TYPE #{e.class.red} WITH MESSAGE #{e.message.red}"
        sleep 3600
      end
    end

    def time_format
      diff = info['next_post'] - Time.now.to_i

      FourPleroma::TIME_FORMAT_RANGES.find{ |k, v| k.cover?(diff) }.last
    end

    def calc_wait
      return info['next_post'] - Time.now.to_f if info['next_post'] > Time.now.to_i

      opt  = oldest_post_time.values.length > 0 ? oldest_post_time.values.min : 0
      ret  = info['queue_wait']
      ret  /= 1+info['based_cringe'].sum { |i, board| board.sum { |tno, t| t['posts'].sum { |pno, p| (p['based'] ? p['based'].length : 0) + (p['fav'] ? p['fav'].length : 0) * 0.5 } } } + info['carried_over_dumps']
      ret  *= (info['no_reacts'].to_f/client.verify_credentials['followers_count'].to_f)
      ret  *= (Time.now.to_f - opt) / info['queue_wait'] if opt > 0
      ret  *= info['no_reacts']

      info['carried_over_dumps'] -= 1 if info['carried_over_dumps'] > 0

      ret
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

    def new_favourite(notif)
      status_id = notif['status']['id']
      tno = nil
      pno = nil
      bnm = nil

      info['targets'].each do |board_name|
        threads = info['based_cringe'][board_name] || []
        threads.each do |thread_no, contents|
          next if contents['posts'].nil?

          pno = contents['posts'].find { |post_no, post_contents| post_contents['pleroma_id'] == status_id }
          pno = pno.first if pno

          if pno
            tno = thread_no
            bnm = board_name
            break
          end
        end

        break if pno
      end

      if tno.nil?
        info['carried_over_dumps'] += 3 # liking a dump means wanting more posts in general
        return
      end

      acct = notif['account']['acct'] || notif['account']['fqn']
      info['based_cringe'][bnm] ||= {}
      info['based_cringe'][bnm][tno] ||= {}
      info['based_cringe'][bnm][tno]['posts'] ||= {}
      info['based_cringe'][bnm][tno]['posts'][pno] ||= {}
      info['based_cringe'][bnm][tno]['posts'][pno]['fav'] ||= []
      info['based_cringe'][bnm][tno]['posts'][pno]['fav'].push(acct)
      info['based_cringe'][bnm][tno]['posts'][pno]['fav'].uniq!

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
      bnm = nil

      info['targets'].collect { |target| target['directory'] }.each do |board_name|
        threads = info['based_cringe'][board_name.filesystem_sanitize] || []
        threads.each do |thread_no, contents|
          next if contents['posts'].nil?

          pno = contents['posts'].find { |post_no, post_contents| post_contents['pleroma_id'] == status_id }
          pno = pno.first if pno

          if pno
            tno = thread_no
            bnm = board_name
            break
          end
        end

        break if pno
      end

      if tno.nil?
        info['carried_over_dumps'] += 5 # Repeating a dump means a greater desire in general for more dumps
        return
      end

      acct = notif['account']['acct'] || notif['account']['fqn']
      
      info['based_cringe'][bnm] ||= {}
      info['based_cringe'][bnm][tno] ||= {}
      info['based_cringe'][bnm][tno]['posts'] ||= {}
      info['based_cringe'][bnm][tno]['posts'][pno] ||= {}
      info['based_cringe'][bnm][tno]['posts'][pno]['based'] ||= []
      info['based_cringe'][bnm][tno]['posts'][pno]['based'].push(acct)
      info['based_cringe'][bnm][tno]['posts'][pno]['based'].uniq!

      if /#(nobot|notag)/i.match(notif['account'].to_s)
        info['notag'] ||= []
        info['notag'].push(acct)
      end

      save_info(info)


      notify_opt_out(acct)
      next_candidate = info['old_threads'][bnm].find { |thr| thr['no'].to_i == tno.to_i }
      return if next_candidate.nil?
      thread = Thread.new(next_candidate)

      puts "REBLOG #{name.cyan} - #{bnm.cyan} - #{tno.cyan}"

      options = queue.select {|x| x[:thread].no == tno.to_s }

      return if options.length == 0

      options.shuffle!
      candidate = options.pop

      queue.reject! { |element| candidate[:post].no == element[:post].no and candidate[:thread].no == element[:thread].no }
    end

    def new_mention(notif)
      cmds = COMMANDS.select { |regex, cmd| regex.match(notif['status']['content']) }
      cmds.each do |cmd|
        send("cmd_#{cmd[1]}".to_sym, notif)
      end

      info['carried_over_dumps'] += 2 if cmds.length == 0 # getting involved in a conversation from a dump, or just in general, indicates wanting more posts
    end

    def new_notification(notif)
      return if notif['id'].nil?
      info['last_notification_id'] = notif['id'].to_i if notif['id'].to_i > info['last_notification_id'].to_i

      meth = "new_#{notif['type']}".to_sym

      send(meth, notif) if self.respond_to?(meth)

      info['no_reacts'] = 1
    end

    def get_directory(target, tno)
      "./files/#{target['directory'].filesystem_sanitize}/#{tno}/"
    end

    def start_build_queue
      puts "4pleroma bot, watching catalogs: #{info['targets'].collect { |t| t['directory'].cyan }.join(", ")}"

      info["threads_touched"] ||= {}

      info['based_cringe'] ||= {}

      while true
        info['targets'].each do |target|
          run_target target
        end

        sleep 60
      end
    end

    def run_target(target)
      puts target if target['directory'].nil?
      queue_start = Dir["./files/#{target['directory'].filesystem_sanitize}/**/*"].length

      info['old_threads'][target['directory']] ||= []

      timestamp = Time.now.to_i

      old_queue_posts = queue.collect { |p| p[:post].no }

      begin
        catalog = JSON.parse(Net::HTTP.get(URI(target['catalog_url'])))
      rescue Net::OpenTimeout
        return
      end
      
      @oldest_post_time[target['directory']] = catalog.last['threads'].last['last_modified']

      catalog = Catalog.new(catalog, schema)

      otn = info['old_threads'][target['directory']].collect { |thr| thr['no'] }
      ntn = catalog.threads.collect { |thr| thr.no }

      dtn = otn - ntn

      dump_threads = dtn.select { |tno| info['based_cringe'][target['directory']][tno] and info['based_cringe'][target['directory']][tno]['posts'] and info['based_cringe'][target['directory']][tno]['posts'].any? { |pno, post| (post['based'] and post['based'].length > 0) or (post['fav'] and post['fav'].length > 0) } }.each do |tno|
        info['carried_over_dumps'] += info['based_cringe'][target['directory']][tno]['posts'].select { |post_no, post| post['based'] || post['fav'] }.length

        mentions = info['based_cringe'][target['directory']][tno]['posts'].collect { |post_no, post| post['based'] ? post['based'] : [] }.flatten
        directory = get_directory(target, tno)

        files = Dir["#{directory}/**/*"]
        next if files.length == 0

        puts "DUMPING #{name.cyan} (#{target['directory'].cyan}) THREAD: #{tno.green} with #{files.length.yellow} posts and with the following mentions: #{mentions.cyan.to_unescaped_s}"
        next if mentions.length == 0

        info['based_cringe'][target['directory']][tno]['untagged'] ||= []
        mentions.reject! { |mention|  info['based_cringe'][target['directory']][tno]['untagged'].include?(mention) }
        mentions.reject! { |mention| info['notag'].include?(mention) }
        mentions.collect! { |mention| "@#{mention}" }

        mentions.uniq!

        post_image(files, "\n#{name} (#{target['directory']}) #{tno} image dump:\n#{info['thread_ops'][target['directory']][tno]}\n\n#{mentions.join(' ')}".gsub("\n\n\n", " "))
      end

      Dir["./files/#{target['directory'].filesystem_sanitize}/*"].each do |fn|
        m = /^\.\/files\/#{target['directory'].filesystem_sanitize}\/(\d+)$/i.match(fn)
        next if m.nil?
        tno = m[1]
        next if ntn.include?(tno)
        directory = get_directory(target, tno)
        FileUtils.remove_dir(directory) if File.directory?(directory)
      end

      deleted_elements = queue.select { |el| dtn.include?(el[:thread].no) }
      queue.reject! { |el| dtn.include?(el[:thread].no) }

      info['thread_ops'][target['directory']] ||= {}
      info['thread_ops'][target['directory']].reject! { |k| dtn.include?(k) }

      puts "Removed the following threads from #{name.cyan} (#{target['directory'].cyan}) due to expiration: #{dtn.red.to_unescaped_s}" if dtn.size > 0

      info['threads_touched'][target['directory']] ||= {}
      info['based_cringe'][target['directory']] ||= {}

      info['threads_touched'][target['directory']].select! { |k, v| ntn.include?(k.to_s) }
      info['based_cringe'][target['directory']].select! {|k, v| ntn.include?(k.to_s) }

      info["old_threads"][target['directory']] = catalog.to_h

      rate_limit_exponent = 0

      catalog.threads.each do |thread|
        next if info["threads_touched"][target['directory']].keys.include?(thread.no) and info["threads_touched"][target['directory']][thread.no] >= (thread.last_modified - info['janny_lag'])
        thread_url = target['thread_url'].gsub("%%NUMBER%%", thread.no)
        begin
          thread.posts = JSON.parse(Net::HTTP.get(URI(thread_url)))["posts"].collect { |p| Post.new(p, schema) }
        rescue JSON::ParserError
          next
        end

        info['thread_ops'][target['directory']][thread.no] = thread.posts.first.body if thread.posts

        thread_words = thread.words.uniq
        thread_badwords = thread_words.select { |tw| info["badwords"].any? { |bw| bw == tw } || info["badregex"].any? { |br| %r{#{br}}i.match(tw) } }

        if thread_badwords.length > 0
          puts "Skipping #{name.cyan} - #{target['directory'].cyan} - #{thread.no.cyan} for detected bad words: #{thread_badwords.red.to_unescaped_s}"
          info["threads_touched"][target['directory']][thread.no] = Time.now.to_i * 2
          next
        end
        
        thread.posts.select { |p| p.posted_at >= info["threads_touched"][target['directory']][thread.no].to_i and p.remote_filename.length > 0 }.each do |p|
          begin
            directory = get_directory(target, thread.no)
            FileUtils.mkdir_p(directory)
            filename = "#{directory}#{p.filename}#{p.ext}"

            url = target['image_url'].gsub("%%TIM%%", p.remote_filename).gsub("%%EXT%%", p.ext)
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

        info["threads_touched"][target['directory']][thread.no] = timestamp.to_i
      end

      new_queue_posts = queue.collect { |p| p[:post].no }

      new_info = info

      save_info(new_info)

      queue_end = Dir["./files/#{target['directory'].filesystem_sanitize}/**/*"].length

      if queue_end > queue_start
        puts "ADDED #{(queue_end - queue_start).green} NEW IMAGES TO #{name.cyan} (#{target['directory'].cyan}), BRINGING THE TOTAL TO #{queue_end.green}"
      elsif queue_end < queue_start
        puts "REMOVED #{(queue_start - queue_end).red} OLD IMAGES TO #{name.cyan} (#{target['directory'].cyan}), BRINGING THE TOTAL TO #{queue_end.red}"
      end

      media_ids_mutex.synchronize { info['media_ids'].select! { |fn, id| Dir["./files/**/*"].include?(fn) } }

    end

    def save_info(new_info)
      f = File.open(filename, "w")
      f.write(JSON.pretty_generate(new_info))
      f.close
    end

    def notify_opt_out(user, message="You reblogged or favorited a post I made. That post came from a thread on #{name}. When the thread dies, all of the images collected from it will be uploaded in a big dump post. You will, by default, be tagged in that dump. If you don't want to ever be tagged in posts by me respond with 'notag' instead.")
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
      filename = (filename.class == Array ? filename : [filename])
      media_ids = []
      begin
        media_ids_mutex.synchronize do
          new_media_ideas = {}
          media_ids = filename.collect { |fn| new_media_ideas[fn] = info['media_ids'][fn] || client.media(fn)['id'] }

          info['media_ids'].merge!(new_media_ideas)
          save_info info
        end
      rescue JSON::ParserError
        return
      end
      
      return if media_ids.length == 0

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
      rescue => e
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

