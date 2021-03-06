require 'ffi-ncurses'
require 'artii'
require 'sequel'
require 'fileutils'

module Pompom
  def self.format_time(number)
    minutes = number / 60
    seconds = number % 60
    sprintf("%02d:%02d", minutes, seconds)
  end

  class Application
    attr_reader :worklog
    
    def initialize(options)
      @options = options
      if options[:no_log]
        @worklog = NullWorkLog.new
      else
        @worklog = Worklog.new(options[:log])
      end
    end

    def run
      new_pomodoro do |pomodoro|
        @worklog.start pomodoro
        pomodoro.tick until pomodoro.finished?
      end
      play_sound
    end

    def cleanup
      @worklog.finish_early
    end
    
    private

    # There has to be a better way of playing sounds through ruby...
    # This will only work if you have sox installed (or a command
    # named /usr/bin/play) and a sound named sound.wav in your
    # ~/.pompom directory.
    def play_sound
      if File.exists?(File.expand_path("~/.pompom/sound.wav")) && File.exists?("/usr/bin/play")
        `play -q ~/.pompom/sound.wav`
      end
    end
    
    def new_pomodoro
      pomodoro = Pomodoro.new(@options[:time], @options[:message])
      view     = View.new(NCursesScreen.new)
      pomodoro.add_observer(view)

      view.run { yield pomodoro }
    end
  end

  class Worklog
    def initialize(path)
      @path = File.expand_path(path)
      @directory = File.dirname(@path)
    end

    def start(pomodoro)
      ensure_present
      @id = @db[:pomodoros].insert(:started_at => Time.now, :message => pomodoro.message, :finished_early => false)
    end

    def finish_early
      @db[:pomodoros].where(:id => @id).update(:finished_early => true)
    end

    private

    def ensure_present
      if File.exists?(@path)
        @db = Sequel.sqlite(@path)
      else
        FileUtils.mkdir_p(@directory) unless File.exists?(@directory)
        @db = Sequel.sqlite(@path)
        @db.create_table :pomodoros do
          primary_key :id
          Time      :started_at
          String    :message
          TrueClass :finished_early
        end
      end
    end
  end

  class NullWorkLog
    def start(pomodoro)
    end

    def finish_early
    end
  end
  
  class Pomodoro
    attr_reader :time_remaining, :message
    attr_writer :system_clock
    
    def initialize(time_remaining=1500, message=nil)
      @time_remaining = time_remaining
      @message = message
      @system_clock = Kernel
      @observers = []
      @finished_early = true
    end

    def add_observer(object)
      @observers << object
    end
    
    def tick
      @system_clock.sleep 1
      @time_remaining -= 1
      @finished_early = false if @time_remaining == 0
      notify_observers
    end

    def finish!
      @time_remaining = 0
      notify_observers
    end

    def finished_early?
      @finished_early
    end
    
    def finished?
      @time_remaining < 1
    end

    private

    def notify_observers
      @observers.each {|o| o.update(self) }
    end
  end

  class View
    attr_writer :asciifier
    
    def initialize(screen)
      @screen = screen
      @asciifier = Asciifier.new
    end

    def run(&block)
      @screen.run(&block)
    end

    def update(pomodoro)
      @screen.display format_for_screen(pomodoro.time_remaining), color(pomodoro), blink(pomodoro)
    end

    private

    def color(pomodoro)
      if pomodoro.time_remaining > 60
        :green
      elsif pomodoro.time_remaining > 15
        :yellow
      else
        :red
      end
    end

    def blink(pomodoro)
      pomodoro.time_remaining < 5
    end
    
    def format_for_screen(time)
      @asciifier.asciify(Pompom.format_time(time))
    end
  end

  class Asciifier
    def initialize
      @asciifier = Artii::Base.new
    end

    def asciify(text)
      result = @asciifier.asciify(text).split("\n")
      # Fix kerning for when 2nd character of minutes is a 4. This fix
      # should really be moved back upstream to the figlet font.
      result[3].sub!(/_\| /, '_|')
      result.join("\n")
    end
  end
  
  class NCursesScreen
    include FFI::NCurses

    def run
      begin
        initscr
        cbreak
        noecho
        start_color
        init_pair(1, COLOR_GREEN, COLOR_BLACK)
        init_pair(2, COLOR_YELLOW, COLOR_BLACK)
        init_pair(3, COLOR_RED, COLOR_BLACK)
        curs_set 0
        yield
      ensure
        endwin
      end
    end

    def display(str, color=:green, blinking=false)
      clear
      text_style = blinking ? A_BLINK : A_NORMAL
      attr_set text_style, color_pair_mapping[color], nil

      y, x = getmaxyx(stdscr)

      lines = str.split("\n")
      padding = (x - lines.first.size) / 2
      ((y - lines.size - 1) / 2).times { addstr("\n") }
      lines.each do |line|
        addstr(" " * padding)
        addstr(line + "\n")
      end
      refresh
    end

    def color_pair_mapping
      {:green => 1,:yellow => 2,:red => 3 }
    end
  end
end
