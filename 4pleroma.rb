require 'json'
require 'net/http'
require 'pry'
require 'colorize'
require 'syndesmos'
require 'timeout'

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
    attr_accessor :schema, :no, :remote_filename, :name, :body, :ext, :posted_at, :filename, :closed

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
      @closed = contents['closed'].to_i
    end
  end

  class Main
    COMMANDS = {
      /notag/i => "notag",
      /[^o]tag/i   => "tag"
    }

    attr_accessor :info, :bearer_token, :instance, :filename, :skip_first, :name, :max_sleep_time, :visibility_listing, :schema, :queue, :sensitive, :oldest_post_time, :carried_over_dumps, :media_ids_mutex, :building_queue_mutex

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

      begin
        Timeout.timeout(30) { @user = client.verify_credentials }
      rescue => e
	log "Could not get credentials because #{e.class.red} had message #{e.message.red}"
	return
      end


      raise "Invalid credentials for #{name}" unless client.valid_credentials?

      @oldest_post_time = {}
      info['carried_over_dumps'] ||= 0
      info['no_reacts'] ||= 1.00
      info['old_threads'] = {} if info['old_threads'].class != Hash
      info['based_cringe'].reject! {|k,v| /^\d+$/.match(k) }

      info['threads_touched'] = {} if ENV['FORCE_CLEAR']

      @media_ids_mutex = Mutex.new
      @building_queue_mutex = Mutex.new

      save_info info
    end

    def log(msg)
      puts "[#{Time.now.to_s.light_blue}, #{name.cyan}] #{msg}"
    end

    def notifications
      begin
	args = { "with_muted" => true, "limit" => 20 }
	args.merge!({'since_id' => info['last_notification_id']}) if info['last_notification_id']
        notifs = client.notifications(args)
	notif_ids = notifs.collect { |notif| notif['id'].to_i }
	info['last_notification_id'] = notif_ids.max.to_i > info['last_notification_id'].to_i ? notif_ids.max.to_i : info['last_notification_id']

	if notifs.length > 0
	  info['no_reacts'] = 0
	  delay_pop
	end

	notifs
      rescue
        []
      end
    end

    def start_pop_queue
      delay_pop if info['next_post'].nil?

      notifications.each do |notif|
	new_notification(notif)
      end

      time_wait = info['next_post'] - Time.now.to_i

      running_threads = {}

      build_queue

      if time_wait > 1
	save_info info
        return
      end

      regex = /^\.\/files\/(\w+)\/(\d+)\/(.+)$/
      filename = info['targets'].collect { |t| t['directory'] }.collect { |t| Dir["./files/#{t.filesystem_sanitize}/**/*"].select { |fn| regex.match(fn) and media_ids_mutex.synchronize { !info['media_ids'].include?(fn) } } }.flatten.sample

      m = regex.match(filename)
      if m.nil?
        save_info info
	return
      end

      candidate = queue.reject { |q| q.nil? }.find { |c|
        c[:thread].no == m[2] and
        c[:post].no == m[3] }


      info['force_mentions'] ||= []

      msg = "<b><a href=\"https://boards.4channel.org#{m[1].gsub('_', '/')}thread/#{m[2]}\">Post From #{m[2]}</a></b>\n\n"
      msg += "#{info['force_mentions'].uniq.reject { |x| info['notag'].include?(x) }.collect{ |x| "@#{x}" }.join(" ")}".strip

      json_res = post_image(filename, msg)

      info['force_mentions'] = []
      log "NEW IMAGE: #{filename.green}"
      delay_pop
      queue.reject! { |el| el[:post].no == m[3] and el[:thread].no == m[2] }
      
      if json_res.nil?
        save_info info
	return
      end

      info['no_reacts'] += 1.00

      info['based_cringe'][m[1]] ||= {}
      info['based_cringe'][m[1]][m[2]] ||= {}
      info['based_cringe'][m[1]][m[2]]['posts'] ||= {}
      info['based_cringe'][m[1]][m[2]]['posts'][m[3]] ||= {}
      info['based_cringe'][m[1]][m[2]]['posts'][m[3]]['pleroma_id'] = json_res['id']

      save_info info
    end

    def delay_pop
      begin
        return unless @already_popped.nil?
	@already_popped = true

        queue_wait = calc_wait
	candidate_time = Time.now.to_i + queue_wait
        info['next_post'] = candidate_time
        popping_time = Time.at(info['next_post']).strftime(time_format)
        client.update_credentials({"fields_attributes": [ { "name": "Bot Author", "value": "@NEETzsche@iddqd.social" }, {"name": "Next Post", "value": popping_time}, {"name": "Posts Since React", "value": info['no_reacts'].to_i.to_s} ]})
        log "WILL POP QUEUE AT: #{popping_time.yellow} (#{queue_wait.yellow}s) (number of posts without reacts: #{info['no_reacts'].to_i.red})"

      rescue => e
        log "FAILED TO DELAY POP FOR ERROR TYPE #{e.class.red} WITH MESSAGE #{e.message.red}"
      end
    end

    def time_format
      diff = info['next_post'] - Time.now.to_i

      FourPleroma::TIME_FORMAT_RANGES.find{ |k, v| k.cover?(diff) }.last
    end

    def calc_wait
      opt  = oldest_post_time.values.length > 0 ? oldest_post_time.values.min : 0
      ret  = info['queue_wait']
      ret /= 1+info['based_cringe'].sum { |i, board| board.sum { |tno, t| t['posts'].sum { |pno, p| (p['based'] ? p['based'].length : 0) + (p['fav'] ? p['fav'].length : 0) * 0.5 } } } + info['carried_over_dumps']
      ret *= info['no_reacts'].to_f
      ret *= (Time.now.to_f - opt) / info['queue_wait'] if opt > 0

      info['carried_over_dumps'] **= 0.5 if info['carried_over_dumps'] > 0 and ret > 0

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
        "in_reply_to_id" => notif['status']['id'],
	"content_type"   => "text/markdown"
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

      return if cmds.length > 0

      acct = notif['account']['acct'] || notif['account']['fqn']
      info['force_mentions'] ||= []
      info['force_mentions'].push(acct)

      @force_mentions_ids ||= []
      @force_mentions_ids.push(notif['status']['id'])

      notif['status']['mentions'].each do |mention|
        info['force_mentions'].push(mention['acct']) unless mention['acct'] == @user['acct'] or mention['acct'] == @user['fqn']
      end

      notify_opt_out(acct, "You mentioned me, presumably to be in the next main image dealing, and so will be tagged in the next post. If you want to opt out of this, message me with a body that contains 'notag'.")

      info['carried_over_dumps'] += 2
    end

    def new_emoji_reaction(notif)
      new_favourite(notif)
    end

    def notif_url_to_post(notif)
      if notif['type'] == 'mention'
	"https://#{instance}/statuses/#{notif['status']['in_reply_to_id']}"
      else
	notif['status']['url'] if notif['status'] and notif['status']['url']
      end
    end

    def new_notification(notif)
      return if notif['id'].nil?

      info['last_notification_id'] = notif['id'].to_i if notif['id'].to_i > info['last_notification_id'].to_i

      acct = notif['account']['acct'] || notif['account']['fqn']

      msg = "New #{notif['type'].cyan} from #{acct.cyan}"
      url = notif_url_to_post(notif)
      msg += ": #{url.green}" if url
      log msg

      meth = "new_#{notif['type'].split(':').last}".to_sym

      send(meth, notif) if self.respond_to?(meth)
    end

    def get_directory(target, tno)
      "./files/#{target['directory'].filesystem_sanitize}/#{tno}/"
    end

    def build_queue
      building_queue_mutex.synchronize do
        info['targets'].each do |target|
          run_target target
        end

	directories = info['targets'].collect { |t| t['directory'] }
	['thread_ops', 'threads_touched', 'based_cringe'].each do |el|
	  info[el].select! { |k,v| directories.include?(k) }
	end
      end


    end

    def run_thread(target, thread)
      return if info["threads_touched"][target['directory']].keys.include?(thread.no) and info["threads_touched"][target['directory']][thread.no] >= (thread.last_modified - info['janny_lag'])
      thread_url = target['thread_url'].gsub("%%NUMBER%%", thread.no)

      #begin
	thread.posts = JSON.parse(Net::HTTP.get_response(URI(thread_url)).body)['posts'].collect { |p| Post.new(p, schema) }
	@threads ||= {}
	@threads[target['directory']] ||= {}
	@threads[target['directory']][thread.no] = thread.posts
      #rescue
      #  thread.posts = []
      #end

      if thread.posts.any? {|post| post.closed == 1 }
        dump_thread(target, thread.no)
        return
      end

      info['thread_ops'][target['directory']][thread.no] = thread.posts.first.body if thread.posts

      thread_words = thread.words.uniq
      thread_badwords = thread_words.select { |tw| info["badwords"].any? { |bw| bw == tw } || info["badregex"].any? { |br| %r{#{br}}i.match(tw) } }

      if thread_badwords.length > 0
        log "Skipping #{target['directory'].cyan} - #{thread.no.cyan} for detected bad words: #{thread_badwords.red.to_unescaped_s}"
        info["threads_touched"][target['directory']][thread.no] = Time.now.to_i * 2
        return
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
          log "Could not save file, yielding error of type #{e.class.red} with message #{e.message.red}"
        end
      end

      info["threads_touched"][target['directory']][thread.no] = Time.now.to_i
    end

    def dump_thread(target, tno)
      info['based_cringe'] ||= {}
      info['based_cringe'][target['directory']] ||= {}
      info['based_cringe'][target['directory']][tno] ||= {}
      info['based_cringe'][target['directory']][tno]['posts'] ||= {}

      info['carried_over_dumps'] += info['based_cringe'][target['directory']][tno]['posts'].select { |post_no, post| post['based'] || post['fav'] }.length

      mentions = info['based_cringe'][target['directory']][tno]['posts'].collect { |post_no, post| post['based'] ? post['based'] : [] }.flatten

      mentions.uniq!
      info['based_cringe'][target['directory']][tno]['untagged'] ||= []
      mentions.reject! { |mention|  info['based_cringe'][target['directory']][tno]['untagged'].include?(mention) }
      mentions.reject! { |mention| info['notag'].include?(mention) }
      mentions.collect! { |mention| "@#{mention}" }

      return if mentions.length == 0

      directory = get_directory(target, tno)

      files = Dir["#{directory}/**/*"]
      info["based_cringe"][target['directory']].delete(tno)
      return if files.length == 0


      log "DUMPING (#{target['directory'].cyan}) THREAD: #{tno.green} with #{files.length.yellow} posts and with the following mentions: #{mentions.cyan.to_unescaped_s}"

      post_image(files, "\n#{name} (#{target['directory']}) #{tno} image dump:\n#{info['thread_ops'][target['directory']][tno]}\n\n#{mentions.join(' ')}".gsub("\n\n\n", " "))
    end

    def run_target(target)
      log target if target['directory'].nil?
      queue_start = Dir["./files/#{target['directory'].filesystem_sanitize}/**/*"].length

      info['old_threads'][target['directory']] ||= []

      old_queue_posts = queue.collect { |p| p[:post].no }

      begin
        catalog = JSON.parse(Net::HTTP.get(URI(target['catalog_url'])))
      rescue
        return
      end
      
      @oldest_post_time[target['directory']] = catalog.last['threads'].last['last_modified']

      catalog = Catalog.new(catalog, schema)

      otn = info["old_threads"][target['directory']].collect { |thr| thr['no'] }
      ntn = catalog.threads.collect { |thr| thr.no }

      dtn = otn - ntn

      dtn.each do |tno|
        dump_thread(target, tno)
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

      log "Removed the following threads (#{target['directory'].cyan}) due to expiration: #{dtn.red.to_unescaped_s}" if dtn.size > 0

      info['threads_touched'][target['directory']] ||= {}
      info['based_cringe'][target['directory']] ||= {}

      info['threads_touched'][target['directory']].select! { |k, v| ntn.include?(k.to_s) }
      info['based_cringe'][target['directory']].select! {|k, v| ntn.include?(k.to_s) }

      info["old_threads"][target['directory']] = catalog.to_h

      rate_limit_exponent = 0

      time_wait = info['next_post'] - Time.now.to_i

      catalog.threads.select { |thr| time_wait <= 0 or info['based_cringe'][target['directory']].keys.include?(thr.no) }.each do |thread|
	run_thread(target, thread)
      end

      new_queue_posts = queue.collect { |p| p[:post].no }

      info['based_cringe'][target['directory']].reject! {|k,v| dtn.include?(k) }
      info['threads_touched'][target['directory']].reject! {|k,v| dtn.include?(k) }

      new_info = info

      save_info(new_info)

      queue_end = Dir["./files/#{target['directory'].filesystem_sanitize}/**/*"].length

      queue_now = Dir["./files/**/*"]

      media_ids_mutex.synchronize { info['media_ids'].select! { |fn, id| queue_now.include?(fn) } }
    end

    def save_info(new_info)
      json = JSON.pretty_generate(new_info)
      return if json.strip.length == 0
      f = File.open(filename, "w")
      f.write(json)
      f.close
    rescue => e
      log "Could not save #{name.cyan} because of error type #{e.class.red} with message #{e.message.red}"
    end

    def notify_opt_out(user, message="You reblogged, favorited, or emoji reacted a post I made. That post came from a thread on #{name}. When the thread dies, all of the images collected from it will be uploaded in a big dump post. You will, by default, be tagged in that dump. If you don't want to ever be tagged in posts by me respond with 'notag' instead.")
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
      new_media_ideas = {}
      begin
        media_ids_mutex.synchronize do
          media_ids = filename.collect { |fn| new_media_ideas[fn] = info['media_ids'][fn] || client.media(fn)['id'] }

          info['media_ids'].merge!(new_media_ideas)
          save_info info
        end
      rescue
        return
      end
      
      return if media_ids.length == 0

      uri = URI.parse("https://#{@instance}/api/v1/statuses")
      header = {
        'Authorization'=> "Bearer #{bearer_token}",
        'Content-Type' => 'application/json'
      }

      id = (@force_mentions_ids || []).sample

      begin
        client.statuses({
          'status'         => "#{info['content_prepend']}#{process_html(message)}#{info['content_append']}".strip,
          'source'         => '4pleroma',
          'visibility'     => visibility_listing,
          'sensitive'      => sensitive,
          'content_type'   => 'text/html',
          'media_ids'      => media_ids,
	  'in_reply_to_id' => id
	}.reject {|k,v| v.nil? })
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

def read_file(fn)
  return unless File.exist?(fn)
  f = File.open(fn, "r")
  r = f.read
  f.close
  r
end

def write_file(fn, content)
  f = File.open(fn, "w")
  r = f.write(content)
  f.close
  r
end

def process_exists?(pid)
  Process.getpgid pid
  true
rescue Errno::ESRCH
  false
end

pid_fn = "4pleroma.pid"

pid = read_file(pid_fn).to_i
if pid > 0 and process_exists?(pid)
  puts "--- RUN SKIPPED (run in media res) ---------------------------------------------".red
  abort
end

write_file(pid_fn, Process.pid.to_s)

config_files = ARGV.select { |x| /\.json$/i.match(x) }

infos = {}
badwords = []
badregex = []
threads = {}

config_files.each do |cf|
  infos[cf] = JSON.parse(File.open(cf, "r").read)
  badwords += infos[cf]["badwords"] if infos[cf]["badwords"].class == Array
  badregex += infos[cf]["badregex"] if infos[cf]["badregex"].class == Array
rescue => e
  puts "Failed to load file #{cf.red}"
end

badwords.uniq!
badregex.uniq!

puts "--- RUN BEGIN ------------------------------------------------------------------".green

config_files.each do |cf|
  infos[cf]["badwords"] = badwords unless infos[cf]["isolated_badwords"] == true
  infos[cf]["badregex"] = badregex unless infos[cf]["isolated_badregex"] == true
  four_pleroma = FourPleroma::Main.new(cf, infos[cf])
  threads["#{cf} pop_queue"] = Thread.new do
    four_pleroma.start_pop_queue
  end
end

threads.each { |cf,thr| thr.join }
