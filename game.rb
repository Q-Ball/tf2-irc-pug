# encoding: UTF-8

# Copyright (C) 2011 by Olivier Matz
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require 'thread'

module Pickup

  class Game < ActiveRecord::Base
    has_many :players, :through => :competes
    has_many :competes
    belongs_to :map
    belongs_to :server
    belongs_to :game_variant
    belongs_to :channel

    @@BLUE = 0
    @@RED = 1

    attr_accessor :bot

    def init_registration
      @maps = {}
      Map.all.each do |m|
        @maps[m.name] = m
      end

      @registered_players = {}
      @left_players = {}
      @n_player_total = 0

      @limits = {}
      @registration = {}
      $classes.each do |c|
        @limits[c] = game_variant.description[ $classes.index(c) ].to_i * 2
        @n_player_total += @limits[c]
        @registration[c] = 0 if @limits[c] > 0
      end

      @pre_start_thread = nil
    end

    def register_player(player, gclass)
      raise "0,1This class is disabled." unless @registration.has_key?(gclass)
 #     raise "0,1Thank you for reading the terms of use #{$terms_of_use_url}, type !accept if you agree with them" unless player.has_accepted_terms_of_use != 0
      raise "0,1Sorry, no free slots available at the moment #{gclass}" unless @registration[gclass] < @limits[gclass]
      raise "0,1Sorry, you were banned" if player.banned?

      # Raise error if player is in the left list and try to rejoin before 60 sec.
      if @left_players.has_key?(player) and @left_players[player] > (Time.now.to_i - 60)
        raise "0,1You can sign up again in #{60 - (Time.now.to_i - @left_players[player])} seconds"
      end

      if @registered_players.has_key?(player)
        # Player is already registered but try to switch class.
        @registration[ $classes[ @registered_players[player].gclass ] ] -= 1
        @registered_players[player].gclass = $classes.index(gclass)
        @registration[gclass] += 1
      else
        # Register player in the game and save a new Compete object.
        @registration[gclass] += 1
        compete = Compete.new
        compete.game = self
        compete.player = player
        compete.ready = false
        compete.gclass = $classes.index(gclass)
        compete.nick = player.user.nick
        @registered_players[player] = compete
        competes.push(compete)
      end

      # If the game is full after the registration, launch a pre_start thread.
      if filled?
        @pre_start_thread = Thread.new { pre_start }
      end
    end

    def unregister_player(player)
      if @registered_players.has_key?(player)
        @registration[ $classes[ @registered_players[player].gclass ] ] -= 1
        competes.delete(@registered_players[player])
        @registered_players.delete(player)

        @left_players[player] = Time.now.to_i

        @pre_start_thread.terminate unless @pre_start_thread.nil?
        return true
      end
      false
    end

    def register_vote(player, map)
      if @registered_players.has_key?(player)
        mapre = Regexp.new(".*" + map + ".*")
        @maps.each do |name, map|
            if mapre.match(name)
              @registered_players[player].map_vote = map
              return name
            end
        end
        raise "0,1No such map '#{map}'."
      end
    end

    def register_ready(player)
      if not filled?
        raise "0,1Registration is still open"
      elsif server.nil?
        raise "0,1Searching for a server"
      end

      if @registered_players.has_key?(player) and not @registered_players[player].ready
        @registered_players[player].ready = true

        unless ready?
          bot.Channel(channel.name).send(not_yet_ready_list)
        end
      end

      if ready?
        @pre_start_thread.terminate
        prepare_pickup
        start_pickup
        server.unlock
        save
        bot.reset_game(channel).set_channel_topic
      end
    end

    def prepare_pickup
      # Make teams
      red_team_skill = 0
      red_team_classes_left = {}

      blue_team_skill = 0
      blue_team_classes_left = {}

      @limits.each do |gclass, limit|
        if @limits[gclass] > 0
          red_team_classes_left[gclass] = limit / 2
          blue_team_classes_left[gclass] = limit / 2
        end
      end

      # Sort players by skill
      sorted_players = []
      @registered_players.each do |player, compete|
        sorted_players.push(player)
      end

      sorted_players = sorted_players.sort { |x,y| x.class_skill( $classes[@registered_players[x].gclass] ) <=> y.class_skill( $classes[@registered_players[y].gclass] ) }

      # Add each player to the team that has the lowest skill sum,
      # accounting class limit. This should give balanced team.
      sorted_players.each do |p|
        gclass = $classes[ @registered_players[p].gclass ]

        if red_team_skill < blue_team_skill or blue_team_classes_left[gclass] == 0
          red_team_skill += p.class_skill(gclass)
          red_team_classes_left[gclass] -= 1
          @registered_players[p].team = @@RED
        else
          blue_team_skill += p.class_skill(gclass)
          blue_team_classes_left[gclass] -= 1
          @registered_players[p].team = @@BLUE
        end
      end

      # Choose map
      map_votes = {}
      Map.all.each do |m|; map_votes[m] = 0; end

      competes.each do |c|; map_votes[c.map_vote] += 1 unless c.map_vote.nil?; end

      max = 0
      map_votes.each do |map, vote|
        max = vote if vote > max
      end

      choosed_maps = map_votes.select { |k,v| v == max }

      self.map = choosed_maps.keys[rand(choosed_maps.keys.size)]
      server.load_cfg(game_variant.cfg_file)
      server.set_map(map.name)
      self.date = Time.now
    end

    def start_pickup
      chan = bot.Channel(channel.name)
      blue_team = []
      red_team = []

      competes.each do |c|
        c.player.user.send("0,1You are #{c.to_s_verbose}")
        c.player.user.send("connect #{server.ip_address}:#{server.port.to_s}; password #{server.password}")
        if c.team == @@BLUE
            blue_team.push(c)
        else
            red_team.push(c)
        end
      end

      msg = "Pickup will take place on the " + self.server.id.to_s + " server, map:" + self.map.name + "\n"
      msg += "Team Blue:: "

      blue_team.each do |c|
        msg += c.nick + ", "
      end
      msg = msg.chop.chop + "\nTeam Red :: "

      red_team.each do |c|
        msg += c.nick + ", "
      end
      msg = msg.chop.chop
      chan.send(msg)
    end

    def pre_start
      begin
        chan = bot.Channel(channel.name)
        status_changed = false
        self.server = nil

        while server.nil?
          candidate_servers = game_variant.servers.where('active = 1 AND number_of_players = 0 AND available = 1 AND llock = 0')
          candidate_servers.each do |s|
            tenminago = Time.at( Time.now.to_i - 10 * 60 ) 
            if s.games.where("date > ?", tenminago).size < 1
              self.server = s
              break
            end
          end

          if not status_changed and server.nil?
            chan.send("0,1No server available, pending...")
            chan.topic="0,1" + ($topic_title_prefix + status + " (waiting for a server)")
            status_changed = true
          end

          sleep(10) if server.nil?
        end

        server.lock

        if status_changed
          chan.send("0,1A server was found.")
          chan.topic="0,1" +($topic_title_prefix + status)
        end

        chan.send(not_yet_ready_list)
      rescue
        puts $!.to_s
      end

      sleep($ready_timeout)

      begin
        @registered_players.each do |player, compete|
          unless compete.ready
            @registration[ $classes[ @registered_players[player].gclass ] ] -= 1
            competes.delete(@registered_players[player])
            @registered_players.delete(player)
            @left_players[player] = Time.now.to_i
          end
        end
        server.unlock
        chan.topic="0,1" + ($topic_title_prefix + status)
      rescue
        puts $!.to_s
        server.unlock
      end
    end

    def status
      status = "8,1" + "#{game_variant.name} :: 0,1"
      @registration.each do |gclass, n|
        status += "#{gclass} #{n}/#{@limits[gclass]} "
        players = []
        @registered_players.each do |player, compete|
          players.push(player) if $classes[compete.gclass] == gclass
        end
        if players.size > 0
          status += "("
          players.each do |p|
            status += p.user.nick + ", "
          end
          status = status.chop.chop + ")"
        end
        status += ", "
      end
      status = status.chop.chop + " Total " + @registered_players.size.to_s
      status += "/" + @n_player_total.to_s
    end

    def not_yet_ready_list
      list = "All players must type the following to start: !ready : "
      @registered_players.each do |player, compete|
        unless compete.ready
            list += compete.nick + ", "
        end
      end
      list.chop.chop
    end

    def map_list
      map_list = ""
      @maps.each do |name, map|
        map_list += "#{name} "
      end
      map_list.chop
    end

    def map_list_url
      map_list = ""
      @maps.each do |name, map|
        map_list += "#{name} #{map.url}"
      end
      map_list.chop
    end

    def filled?
      @registration.each do |gclass, n|
        return false if n < @limits[gclass]
      end
      true
    end

    def ready?
      @registered_players.each do |player, compete|
        return false unless @registered_players[player].ready
      end
      filled?
    end

    def to_s
      "0,1Pickup number #{id.to_s} - #{date.to_datetime.to_s} at the #{server.ip_address}:#{server.port.to_s}"
    end

    def to_s_verbose
      msg = to_s
      competes.each do |c|
        msg += "\n#{c.to_s}"
      end
      msg
    end

    def set_channel_topic
      bot.Channel(channel.name).topic=($topic_title_prefix + status)
    end
  end

end
