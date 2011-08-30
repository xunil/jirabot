#!/usr/bin/env ruby
require 'rubygems'
require 'yaml'
require 'eventmachine'
require 'isaac/bot'
require 'jira4r'
require 'jira4r/jira_tool'
gem 'soap4r'
require 'soap/mapping'


# [OPS-748] #<Jira4R::V2::RemoteIssue:0x2b1e7f4f8300 
#   @summary="Test issue", 
#   @assignee="xunil", 
#   @description="Nothing to see here, move along.", 
#   @priority="6", 
#   @customFieldValues=[#<Jira4R::V2::RemoteCustomFieldValue:0x2b1e7f4f43b8 
#     @customfieldId="customfield_10031", 
#     @values=["Trival"], 
#     @key=nil>
#   ], 
#   @updated=#<DateTime: 212181071029/86400,0,2299161>, 
#   @affectsVersions=[], 
#   @votes=0, 
#   @created=#<DateTime: 35363511823/14400,0,2299161>, 
#   @fixVersions=[], 
#   @components=[], 
#   @resolution="1", 
#   @environment=nil, 
#   @attachmentNames=[], 
#   @id="15481", 
#   @type="17", 
#   @project="OPS", 
#   @reporter="xunil", 
#   @key="OPS-748", 
#   @status="5", 
#   @duedate=#<DateTime: 4919121/2,0,2299161>>

class JiraBot
  def initialize
    @config = YAML.load(File.open('jirabot.yaml'))
    if @config[:irc].has_key?(:logdir)
      Dir.chdir(@config[:irc][:logdir])
    end

    @jira = Jira4R::JiraTool.new(2, @config[:jira][:url])
    @jira.login(@config[:jira][:user], @config[:jira][:password])

    @bot = Isaac::Bot.new do
      configure do |c|
        c.nick = @config[:irc][:nick]
        c.server = @config[:irc][:server]
        c.port = @config[:irc][:port] 
        c.ssl = @config[:irc][:ssl]
        c.password = @config[:irc][:password]
        c.verbose = @config[:irc].has_key?(:verbose) ? @config[:irc][:verbose] : false
      end

      # Helpers
      helpers do
        def is_admin?(nick)
          if not @config[:irc].has_key?(:admins) or @config[:irc][:admins].empty?
            # Everyone is an admin!
            return true
          end

          @config[:irc][:admins].each do |admin_nick|
            if admin_nick == nick
              return true
            end
          end

          return false
        end

        def help_message(nick)
          msg nick, "jirabot understands !quit, !join #channel, !part, and !help."
          msg nick, "!part will leave the channel in which the command is heard."
          msg nick, "only admins can use !quit, !join, and !part."
        end
      end

      on :connect do
        if not @config[:irc].has_key?(:channels) or @config[:irc][:channels].empty?
          join '#jirabot'
        else
          @config[:irc][:channels].each {|c| join c}
        end
      end

      # Commands
      on :channel, /^\!(help|quit|part|join)([ \t]+.*)*$/ do
        if is_admin?(nick)
          case match[0]
            when "quit"
              quit "Requested to quit"
              EventMachine.stop
            when "part"
              part channel
            when "join"
              join match[1]
          end
        end

        case match[0]
          when "help"
            help_message(nick)
        end
      end
    end
  end

  def run
    EventMachine.run do
      EventMachine.add_periodic_timer(60) { scan_for_updated_tickets }
      @bot.start
    end
  end

  def scan_for_updated_tickets
    issues = @jira.getIssuesFromFilter('10237')
    keys = issues.map {|i| i.key}
    keys.each do |key|
      issue = @jira.getIssue(key)
      @config[:irc][:channels].each do |channel|
        @bot.msg(channel, "[#{issue.key}] #{issue.description} (#{issue.reporter})")
      end
    end
  end
end

jira_bot = JiraBot.new
jira_bot.run
