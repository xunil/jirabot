#!/usr/bin/env ruby
# vim:ts=2:sts=2:sw=2:et:ft=ruby
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
    @statuses = @jira.getStatuses().inject({}) {|result, element| result.merge({element.id => element.name})}
    @priorities = @jira.getPriorities().inject({}) {|result, element| result.merge({element.id => element.name})}


    $irc_config = @config[:irc]
    @bot = Isaac::Bot.new do
      configure do |c|
        c.nick = $irc_config[:nick]
        c.server = $irc_config[:server]
        c.port = $irc_config[:port] 
        c.ssl = $irc_config[:ssl]
        c.password = $irc_config[:password]
        c.verbose = $irc_config.has_key?(:verbose) ? $irc_config[:verbose] : false
      end

      # Helpers
      helpers do
        def is_admin?(nick)
          if not $irc_config.has_key?(:admins) or $irc_config[:admins].empty?
            # Everyone is an admin!
            return true
          end

          $irc_config[:admins].each do |admin_nick|
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
        if not $irc_config.has_key?(:channels) or $irc_config[:channels].empty?
          join '#jirabot'
        else
          $irc_config[:channels].each {|c| join c}
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

  def scan_for_updated_tickets
    messages = []

    issues = @jira.getIssuesFromFilter('10237')
    keys = issues.map {|i| i.key}
    keys.each do |key|
      issue = @jira.getIssue(key)

      new_text = ''
      if issue.created == issue.updated
        # new ticket
        new_text = "\033[0;31m(NEW)\033[0m"
      end

      width = (@config[:jira].has_key?(:summary_width) ? @config[:jira][:summary_width] : 50)
      trimmed_summary = ( issue.summary.length > width ? issue.summary[0,width-3] + '...' : issue.summary )
      messages << "\033[0;32m[#{issue.key}]\033[0m#{new_text}\033[0;33m(#{@priorities[issue.priority]}/#{@statuses[issue.status]})\033[0m #{trimmed_summary} \033[0;32m(#{issue.reporter})\033[0m"

      comments = @jira.getComments(key)

      comments.each do |comment|
        if comment.updated == issue.updated or comment.created == issue.updated
          # new comment
          trimmed_comment_text = (comment.body.length > width ? comment.body[0,width-3] + '...' : comment.body)
          messages << "\033[0;33m - Comment from \033[0;32m#{comment.author}: \033[0m#{trimmed_comment_text}"
        end
      end
    end

    @config[:irc][:channels].each do |channel|
      messages.each do |message_text|
        @bot.msg(channel, message_text)
        puts message_text
      end
    end
  end

  def run
    EventMachine.run do
      EventMachine.add_periodic_timer(@config[:jira][:interval]) { EM.defer { scan_for_updated_tickets } }
      EM.defer {@bot.start}
    end
  end
end

jira_bot = JiraBot.new
jira_bot.run
