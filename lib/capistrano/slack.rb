require 'capistrano'
require 'capistrano/log_with_awesome'
require 'json'
require 'net/http'
require 'active_support/all'
# TODO need to handle loading a bit beter. these would load into the instance if it's defined
module Capistrano
  module Slack
    
    def default_payload
      {
        'channel' => fetch(:slack_room),
        'username' => fetch(:slack_username, ''), 
        'icon_emoji' => fetch(:slack_emoji, '') 
      }
    end
  
    def payload(announcement)
      default_payload.merge(text: announcement)
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
      diff = `git log #{base_rev}..#{new_rev} --oneline`
      messages = diff.split("\n")
      
      repo = fetch(:repository, "")
      repo_url = nil
      if m = repo.match /git@github.com:([^\/]+)\/([^(\.git)]+).git/
        git_org = m.to_a[1]
        git_repo = m.to_a[2]
        repo_url = "https://github.com/#{git_org}/#{git_repo}/"
      end
      
      if repo_url
        messages.map do |message|
          message_pieces = message.split(" ")
          commit_sha = message_pieces[0]
          commit_url = "#{repo_url}/commit/#{commit_sha}"
          message_pieces[0]= "<#{commit_url}|#{commit_sha}>" 
          message_pieces.join(" ")
        end
      end
      
      messages
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
              "#{announced_deployer} is deploying #{slack_application}'s #{branch} to #{fetch(:stage, 'production')}"
            else
              "#{announced_deployer} is deploying #{slack_application} to #{fetch(:stage, 'production')}"
            end

            slack_connect(payload(msg))  
            set(:start_time, Time.now)
          end
          
          task :finished do
            begin
              return if slack_token.nil?
              announced_deployer = fetch(:deployer)
              slack_send_commits = fetch(:slack_send_commits, false)
              start_time = fetch(:start_time)
              elapsed = Time.now.to_i - start_time.to_i
              msg = "#{announced_deployer} deployed #{slack_application} successfully in #{elapsed} seconds."
              payload = payload(msg)
              if slack_send_commits && messages = commit_messages
                payload[:fields] = messages
              end
              slack_connect(payload)
            rescue Faraday::Error::ParsingError
              # FIXME deal with crazy color output instead of rescuing
              # it's stuff like: ^[[0;33m and ^[[0m
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
  
