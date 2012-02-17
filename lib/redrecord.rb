
require 'timeout'

class Redrecord

  class << self
    attr_accessor :redis, :enabled, :write_only, :timeout
    def update_queue
      Thread.current[:redrecord_update_queue] ||= []
    end
    def is_marshalled?(str)
      Marshal.dump(nil)[0,2] == str[0,2]
    end
    def unmarshal(str)
      if(is_marshalled?(str))
        Marshal.load(str)
      elsif(str =~ /^\d+$/)
        str.to_i
      else
        str
      end
    end
    def marshal(obj)
      if Integer===obj || String===obj && obj !~ /^\d+$/ && !is_marshalled?(obj)
        obj.to_s
      else
        Marshal.dump(obj)
      end
    end
    def redis_op(op, *args)
      if @enabled
        begin
          Timeout.timeout(@timeout || 15) do
            redis.send(op, *args)
          end
        rescue Exception => e
          $stderr.puts "Redrecord: Disabling redis due to exception (#{e})"
          @enabled = false
        end
      end
    end
  end

  module Model

    module ClassMethods

      def redrecord_cached_fields
        @redrecord_cached_fields ||= [] + (superclass.respond_to?(:redrecord_cached_fields) ? [*superclass.redrecord_cached_fields] : [])
      end

      def redrecord_invalidation_fields
        @redrecord_invalidation_fields ||= [] + (superclass.respond_to?(:redrecord_invalidation_fields) ? [*superclass.redrecord_invalidation_fields] : [])
      end
      
      def redis_cache(*fields, &bl)
        if block_given?
          old_methods = instance_methods
          class_eval(&bl)
          fields.push(*(instance_methods - old_methods))
        end
        fields = fields.select {|f| instance_method(f).arity < 1 }
        redrecord_cached_fields.push(*fields)
        fields.each do |f|
          aliased_target, punctuation = f.to_s.sub(/([?!=])$/, ''), $1
          define_method("#{aliased_target}_with_cache#{punctuation}") do
            cached_method(f)
          end
          alias_method_chain f, :cache
        end
      end
      
      def invalidate_cache_on(fieldname)
        redrecord_invalidation_fields << fieldname.to_sym 
      end
      
    end
    
    def self.included(mod)
      mod.extend(ClassMethods)
      mod.send(:after_save,     :redrecord_update_queue_save)
      mod.send(:after_destroy,  :redrecord_update_queue_destroy)
      mod.send(:after_commit,   :redrecord_update_queue_commit)
      mod.send(:after_rollback, :redrecord_update_queue_rollback)
    end
    
    def redrecord_update_queue_save
      Redrecord.update_queue << [:save, self] unless self.class.redrecord_cached_fields.empty?
      invalidations_for_redrecord_update_queue
    end
    
    def invalidations_for_redrecord_update_queue
      self.class.redrecord_invalidation_fields.each do |f|
        if((field_value = send(f)).kind_of?(Array))
          field_value.each {|item|  Redrecord.update_queue << [:save, item] } 
        else
          Redrecord.update_queue << [:save, field_value] if field_value
        end
      end
    end

    def redrecord_update_queue_destroy
      Redrecord.update_queue << [:destroy, self] unless self.class.redrecord_cached_fields.empty?
      invalidations_for_redrecord_update_queue
    end
    
    def redrecord_update_queue_rollback
      Redrecord.update_queue.clear
    end
    
    def redrecord_update_queue_commit
      Redrecord.update_queue.each do |command, record|
        if command == :destroy
          record.remove_from_cache!
        elsif command == :save
          record.add_to_cache!
          # possible todo: cascade invalidation (but avoid loops)
        end
      end
      Redrecord.update_queue.clear
    end
    
    def redrecord_key
      "#{self.class.table_name}:#{self.id}"
    end
    
    def remove_from_cache!
      Redrecord.redis_op :del, redrecord_key
    end
    
    def add_to_cache!
      Redrecord.redis_op(:hmset, redrecord_key,
        *(self.class.redrecord_cached_fields.map {|f|
          aliased_target, punctuation = f.to_s.sub(/([?!=])$/, ''), $1
          val = send("#{aliased_target}_without_cache#{punctuation}")
          [f.to_s, Redrecord.marshal(val)]
        }.flatten)
      )
    end
    
    def verify_cache!
      (redis_cached_keys = Redrecord.redis_op(:hkeys, redrecord_key)) && redis_cached_keys.each do |key|
        calculated = redrecord_uncached_value(key)
        cachedval = Redrecord.unmarshal(Redrecord.redis_op(:hget, redrecord_key, key))
        if(calculated != cachedval)
          raise "#{redrecord_key}.#{key}: expected <#{calculated}> but got <#{cachedval}> from redis cache"
        end
      end
    end

    def cached_method(method_name)
      redrecord_cached_attrib_hash[method_name.to_sym]
    end

    def redrecord_redis_cache
      @redrecord_redis_cache ||= Redrecord.redis_op(:hgetall, redrecord_key) unless Redrecord.write_only
    end

    def redrecord_cached_attrib_hash
      @redrecord_cached_attrib_hash ||= Hash.new do |h,k|
        h[k.to_sym] = if(cached = (redrecord_redis_cache && redrecord_redis_cache[k.to_s] unless new_record?))
          Redrecord.unmarshal(cached)
        else
          redrecord_uncached_value(k)
        end
      end
    end
    
    def redrecord_uncached_value(fieldname)
      aliased_target, punctuation = fieldname.to_s.sub(/([?!=])$/, ''), $1
      send("#{aliased_target}_without_cache#{punctuation}")
    end

    def attribs_with_cached_fields
      attributes.merge(cached_fields)
    end

    def cached_fields
      self.class.redrecord_cached_fields.inject({}) {|hsh,field| hsh[field] = send(field) ; hsh }
    end

  end
  
end

