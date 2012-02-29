# encoding: UTF-8

require "base64"
require "digest/sha1"
require "redis"
require "nest"

module Ohm
  class Error < StandardError; end
  class MissingID < Error; end
  class IndexNotFound < Error; end
  class UniqueIndexViolation < Error; end

  ROOT = File.expand_path("../", File.dirname(__FILE__))

  module Utils
    def self.const(context, name)
      case name
      when Symbol then context.const_get(name)
      else name
      end
    end
  end

  class Connection
    attr_accessor :context
    attr_accessor :options

    def initialize(context = :main, options = {})
      @context = context
      @options = options
    end

    def reset!
      threaded[context] = nil
    end

    def start(options = {})
      self.options = options
      self.reset!
    end

    def redis
      threaded[context] ||= Redis.connect(options)
    end

    def threaded
      Thread.current[:ohm] ||= {}
    end
  end

  def self.conn
    @conn ||= Connection.new
  end

  def self.connect(options = {})
    conn.start(options)
  end

  def self.redis
    conn.redis
  end

  def self.flush
    redis.flushdb
  end

  class Collection < Struct.new(:key, :namespace, :model)
    include Enumerable

    def all
      fetch(ids)
    end

    def each
      all.each { |e| yield e }
    end

    def empty?
      size == 0
    end

    def sort(options = {})
      if options.has_key?(:get)
        options[:get] = namespace["*->%s" % options[:get]]
        return key.sort(options)
      end

      fetch(key.sort(options))
    end

    def sort_by(att, options = {})
      sort(options.merge(by: namespace["*->%s" % att]))
    end

  private
    def fetch(ids)
      arr = model.db.pipelined do
        ids.each { |id| namespace[id].hgetall }
      end

      return [] if arr.nil?

      arr.map.with_index do |atts, idx|
        model.new(Hash[*atts].update(id: ids[idx]))
      end
    end
  end

  class List < Collection
    def ids
      key.lrange(0, -1)
    end

    def size
      key.llen
    end

    def first
      model[key.lindex(0)]
    end

    def last
      model[key.lindex(-1)]
    end

    def include?(model)
      ids.include?(model.id.to_s)
    end

    def replace(models)
      ids = models.map { |model| model.id }

      model.db.multi do
        key.del
        ids.each { |id| key.rpush(id) }
      end
    end
  end

  class Set < Collection
    def first(options = {})
      opts = options.dup
      opts.merge!(limit: [0, 1])

      if opts[:by]
        sort_by(opts.delete(:by), opts).first
      else
        sort(opts).first
      end
    end

    def ids
      key.smembers
    end

    def include?(record)
      key.sismember(record.id)
    end

    def size
      key.scard
    end

    def [](id)
      model[id] if key.sismember(id)
    end

    def replace(models)
      ids = models.map { |model| model.id }

      key.redis.multi do
        key.del
        ids.each { |id| key.sadd(id) }
      end
    end
  end

  class Model
    def self.conn
      @conn ||= Connection.new(name)
    end

    def self.connect(options)
      @key = nil
      @lua = nil
      conn.start(options)
    end

    def self.db
      conn.redis
    end

    def self.lua
      @lua ||= Lua.new(File.join(Ohm::ROOT, "lua"), db)
    end

    def self.key
      @key ||= Nest.new(self.name, db)
    end

    def self.[](id)
      new(id: id).load! if id && exists?(id)
    end

    def self.to_proc
      lambda { |id| self[id] }
    end

    def self.exists?(id)
      key[:all].sismember(id)
    end

    def self.new_id
      key[:id].incr
    end

    def self.with(att, val)
      id = key[:uniques][att].hget(val)
      id && self[id]
    end

    def self.find(hash)
      unless hash.kind_of?(Hash)
        raise ArgumentError,
          "You need to supply a hash with filters. " +
          "If you want to find by ID, use #{self}[id] instead."
      end

      keys = hash.map { |k, v| key[:indices][k][v] }

      # FIXME: this should do the old way of SINTERing stuff.
      Ohm::Set.new(keys.first, key, self)
    end

    def self.index(attribute)
      key[:indices].sadd(attribute)
    end

    def self.unique(attribute)
      key[:uniques].sadd(attribute)
    end

    def self.list(name, model)
      key[:lists].sadd(name)

      define_method name do
        Ohm::List.new(key[name], model.key, Utils.const(self.class, model))
      end
    end

    def self.set(name, model)
      key[:sets].sadd(name)

      define_method name do
        Ohm::Set.new(key[name], model.key, Utils.const(self.class, model))
      end
    end

    def self.attribute(name, cast = nil)
      if cast
        define_method(name) do
          cast[@attributes[name]]
        end
      else
        define_method(name) do
          @attributes[name]
        end
      end

      define_method(:"#{name}=") do |value|
        @attributes[name] = value
      end
    end

    def self.counter(name)
      define_method(name) do
        return 0 if new?

        key[:counters].hget(name).to_i
      end

      key[:counters].sadd(name)
    end

    def self.all
      Set.new(key[:all], key, self)
    end

    def self.create(atts = {})
      new(atts).save
    end

    def model
      self.class
    end

    def db
      model.db
    end

    def key
      model.key[id]
    end

    def initialize(atts = {})
      @attributes = {}
      update_attributes(atts)
    end

    def id
      raise MissingID if not defined?(@id)
      @id
    end

    def ==(other)
      other.kind_of?(model) && other.key == key
    rescue MissingID
      false
    end

    def load!
      update_attributes(key.hgetall) unless new?
      return self
    end

    def new?
      !defined?(@id)
    end

    def save
      response = model.lua.run("save",
        keys: [model, (key unless new?)],
        argv: @attributes.flatten)

      case response[0]
      when 200
        @id = response[1][1]
      when 500
        raise UniqueIndexViolation, "#{response[1][0]} is not unique"
      end

      return self
    end

    def incr(att, count = 1)
      key[:counters].hincrby(att, count)
    end

    def decr(att, count = 1)
      incr(att, -count)
    end

    def hash
      new? ? super : key.hash
    end
    alias :eql? :==

    def attributes
      @attributes
    end

    def to_hash
      attrs = {}
      attrs[:id] = id unless new?

      return attrs
    end

    def to_json
      to_hash.to_json
    end

    def update(attributes)
      update_attributes(attributes)
      save
    end

    def update_attributes(atts)
      atts.each { |att, val| send(:"#{att}=", val) }
    end

    def delete
      model.lua.run("delete", keys: [model, key])
    end

  protected
    attr_writer :id
  end

  class Lua
    attr :dir
    attr :redis
    attr :cache

    def initialize(dir, redis)
      @dir = dir
      @redis = redis
      @cache = Hash.new { |h, cmd| h[cmd] = read(cmd) }
    end

    def run(command, options)
      keys = options[:keys]
      argv = options[:argv]

      begin
        redis.evalsha(sha(command), keys.size, *keys, *argv)
      rescue RuntimeError
        redis.eval(cache[command], keys.size, *keys, *argv)
      end
    end

  private
    def read(name)
      minify(File.read("%s/%s.lua" % [dir, name]))
    end

    def minify(code)
      code.
        gsub(/^\s*--.*$/, ""). # Remove comments
        gsub(/^\s+$/, "").     # Remove empty lines
        gsub(/^\s+/, "")       # Remove leading spaces
    end

    def sha(command)
      Digest::SHA1.hexdigest(cache[command])
    end
  end
end
