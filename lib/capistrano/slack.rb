require 'capistrano'
require 'capistrano/log_with_awesome'
require 'json'
require 'net/http'
require 'active_support/all'
# TODO need to handle loading a bit better. these would load into the instance if it's defined
module Capistrano
  module Slack

    def default_payload
      {
        'channel' => fetch(:slack_room),
        'username' => fetch(:slack_username, ''),
        'icon_emoji' => fetch(:slack_emoji, '')
      }
    end

    def current_stage
      fetch(:stage, :production)
    end

    def payload(announcement)
      default_payload.merge(text: announcement)
    end

    def slack_send_message(message)
      slack_connect(payload(message))
    end

    def slack_connect(payload)
      begin
        uri = URI.parse("https://#{fetch(:slack_subdomain)}.slack.com/services/hooks/incoming-webhook?token=#{fetch(:slack_token)}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        request = Net::HTTP::Post.new(uri.request_uri)
        request.set_form_data(:payload => payload.to_json)
        http.request(request)
      rescue SocketError => e
         puts "#{e.message} or slack may be down"
       end
    end

    def slack_defaults
      if fetch(:slack_deploy_defaults, true) == true
        before 'deploy', 'slack:starting'
        before 'deploy:migrations', 'slack:starting'
        after 'deploy', 'slack:finished'
        after 'deploy:migrations',  'slack:finished'
      end
    end

    def commit_messages
      current, previous, branch = fetch(:current_revision), fetch(:previous_revision), fetch(:branch)
      base_rev, new_rev = branch != "master" ? ["master", branch] : [previous, current]
      # Show difference between master and deployed revisions.
      diff = `git log #{base_rev}..#{new_rev}  --format="%h,%an,%ai,%f"`
      messages = diff.split("\n")

      repo = fetch(:repository, "")
      repo_url = nil
      if m = repo.match(/git@github.com:([^\/]+)\/([^(\.git)]+).git/)
        git_org = m.to_a[1]
        git_repo = m.to_a[2]
        repo_url = "https://github.com/#{git_org}/#{git_repo}"
      end

      messages.map! do |message|
        sha, author, date, subject = message.split(",")
        link = sha
        if repo_url
          commit_url = "#{repo_url}/commit/#{sha}"
          link = "<#{commit_url}|#{sha}>"
        end
        "****** #{link} by #{author} at #{date} ******\n#{subject}"
      end

      messages
    end

    def product_notes
      log_delimiter = ' alexandjuliawerehere '
      commit_delimiter = '[END COMMIT]'
      pm_note_token = fetch(:slack_product_updates_flag)

      current, previous, branch = fetch(:current_revision), fetch(:previous_revision), fetch(:branch)
      base_rev, new_rev = branch != "master" ? ["master", branch] : [previous, current]
      # Show difference between master and deployed revisions.
      diff = `git log #{base_rev}..#{new_rev}  --format="%an#{log_delimiter}%b#{commit_delimiter}"`
      changes = diff.split(commit_delimiter).reject(&:empty?)

      notes = []
      changes.each do |change|
        author, body = change.split(log_delimiter)
        next unless body
        comments = body.split("\n")
        comment_with_note = comments.find {|comment| comment.downcase.start_with? pm_note_token.downcase}
        next unless comment_with_note
        note = comment_with_note.match(/#{Regexp.quote(pm_note_token)}(.*)/i)[1].strip
        notes << "#{author}: #{note}"
      end

      notes
    end

    def messages_payload(msg, title, messages, channel=nil)
      payload = default_payload
      payload[:attachments] = [{
          fields: [{
              title: title,
              value: messages.join("\n"),
              short: false
            }],
          fallback: msg,
          pretext: msg
        }]
      payload['channel'] = channel if channel
      payload
    end

    def send_commit_messages
      announced_deployer = fetch(:deployer)
      start_time = fetch(:start_time)
      elapsed = Time.now.to_i - start_time.to_i
      msg = "#{announced_deployer} deployed #{slack_application} successfully to #{current_stage} in #{elapsed} seconds."
      payload = payload(msg)
      messages = commit_messages
      if messages.any?
        title = "#{messages.count} commits"
        payload = messages_payload(msg, title, messages)
      end

      slack_connect(payload)
    end

    def send_product_notes
      notes = product_notes
      if current_stage == :production && notes.any?
        msg = 'New product updates deployed!'
        payload = messages_payload(msg, '', notes, fetch(:slack_room_product_updates))
        slack_connect(payload)
      end
    end

    def self.extended(configuration)
      configuration.load do

        before('deploy') do
          slack_defaults
        end

        set :deployer do
          ENV['GIT_AUTHOR_NAME'] || `git config user.name`.chomp
        end

        namespace :slack do
          task :starting do
            return if slack_token.nil?
            announced_deployer = ActiveSupport::Multibyte::Chars.new(fetch(:deployer)).mb_chars.normalize(:kd).gsub(/[^\x00-\x7F]/,'').to_s
            msg = if fetch(:branch, nil)
              "#{announced_deployer} is deploying #{slack_application}'s #{branch} to #{current_stage}"
            else
              "#{announced_deployer} is deploying #{slack_application} to #{current_stage}"
            end

            slack_connect(payload(msg))
            set(:start_time, Time.now)
          end

          task :finished do
            return if slack_token.nil?

            if fetch(:slack_send_commits, false)
              send_commit_messages
              send_product_notes
            end
          end
        end
      end
    end
  end
end

if Capistrano::Configuration.instance
  Capistrano::Configuration.instance.extend(Capistrano::Slack)
end

