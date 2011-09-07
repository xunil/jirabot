#!/usr/bin/env ruby
# vim:ts=2:sts=2:sw=2:et:ft=ruby
require 'rubygems'
require 'yaml'
require 'net/http'
require 'cgi'
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

Colors = {
  :black   => 30,
  :red     => 31,
  :green   => 32,
  :yellow  => 33,
  :blue    => 34,
  :magenta => 35,
  :cyan    => 36,
  :white   => 37,
}

class JiraBot
  def initialize
    @config = YAML.load(File.open('jirabot.yaml'))
    if @config[:irc].has_key?(:logdir)
      Dir.chdir(@config[:irc][:logdir])
    end

    if @config[:jira].has_key?(:apiurl)
      api_url = @config[:jira][:apiurl]
    else
      api_url = @config[:jira][:url]
    end

    @jira = Jira4R::JiraTool.new(2, api_url)
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

  def shorten_url(url)
    res = Net::HTTP.get_response(
            URI.parse("http://api.bit.ly/v3/shorten?" +
                        "login=#{@config[:bitly][:username]}" +
                        "&apiKey=#{@config[:bitly][:apikey]}" +
                        "&longUrl=#{CGI.escape(url)}" +
                        "&format=txt")
            )

    if res.code.to_i != 200
      puts "Error from bit.ly: (#{res.code}) #{res.body}"
      return nil
    end

    return res.body.strip[7,res.body.strip.length]
  end

  def colorize(str, color, bright=false)
    "\033[#{bright ? 1 : 0};#{Colors[color].to_s}m#{str}\033[0m"
  end

  def trim_to_width(str, width)
    ( str.length > width ? str[0,width-3] + '...' : str )
  end

  def scan_for_updated_tickets
    messages = []

    issues = @jira.getIssuesFromFilter('10237')
    keys = issues.map {|i| i.key}
    keys.each do |key|
      puts "Examining #{key}"
      issue = @jira.getIssue(key)


      new_flag = false
      comment_text = nil
      colorized_comment_text = nil
      colorized_short_url = nil
      url_args = nil

      if issue.created == issue.updated
        # new ticket
        new_flag = true
      end

      comments = @jira.getComments(key)

      comments.each do |comment|
        if comment.updated == issue.updated or comment.created == issue.updated
          # new comment
          comment_text = trim_to_width(comment.body, @config[:jira][:summary_width])
          colorized_comment_text = colorize(" - Comment from", :yellow) + " " + colorize(comment.author, :green) + " " + comment_text
          url_args = "?focusedCommentId=#{comment.id}#comment-#{comment.id}"
        end
      end

      short_url = shorten_url(@config[:jira][:url] + "browse/" + key + (url_args.nil? ? '' : url_args))
      if not short_url.nil?
        colorized_short_url = colorize(short_url, :cyan)
      end

      message_text = colorize(issue.key, :green) +
          " " + colorize("(#{@priorities[issue.priority]}/#{@statuses[issue.status]})", :yellow) +
          " " + trim_to_width(issue.summary, @config[:jira][:summary_width]) +
          " " + colorize("(#{issue.reporter})", :green) +
          " " + colorized_short_url

      messages << message_text
      if not colorized_comment_text.nil?
        messages << colorized_comment_text
      end
    end


    @config[:irc][:channels].each do |channel|
      messages.each do |text|
        @bot.msg(channel, text)
        puts text
      end
    end
  end

  def run
    EventMachine.run do
      EventMachine.add_periodic_timer(@config[:jira][:interval]) do
        EM.defer do
          scan_for_updated_tickets
        end
      end
      EM.defer {@bot.start}
    end
  end
end

jira_bot = JiraBot.new
jira_bot.run
