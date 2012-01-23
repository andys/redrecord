
class Redrecord

  class << self
    attr_accessor :redis
    def update_queue
      Thread.current[:redrecord_update_queue] ||= []
    end
    def is_marshalled?(str)
      Marshal.dump(nil)[0,2] == str[0,2]
    end
  end

  module Model

    module ClassMethods

      def redrecord_cached_fields
        @redrecord_cached_fields ||= []
      end

      def redrecord_invalidation_fields
        @redrecord_invalidation_fields ||= []
      end
      
      def cache(*fields, &bl)
        if block_given?
          old_methods = instance_methods
          class_eval(&bl)
          fields.push(*(instance_methods - old_methods))
        end
        redrecord_cached_fields.push(*fields)
        fields.each do |f|
          define_method "#{f}_with_cache" do
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
        end
      end
      Redrecord.update_queue.clear
    end
    
    def redrecord_key
      "#{self.class.table_name}:#{self.id}"
    end
    
    def remove_from_cache!
      Redrecord.redis.del redrecord_key
    end
    
    def add_to_cache!
      Redrecord.redis.hmset(redrecord_key,
        *(self.class.redrecord_cached_fields.map {|f|
          val = send("#{f}_without_cache")
          [f.to_s, String===val && !Redrecord.is_marshalled?(val) ? val : Marshal.dump(val)]
        }.flatten)
      )
    end

    def cached_method(method_name)
      redrecord_cached_attrib_hash[method_name.to_sym]
    end

    def redrecord_redis_cache
      @redrecord_redis_cache ||= Redrecord.redis.hgetall(redrecord_key)
    end

    def redrecord_cached_attrib_hash
      @redrecord_cached_attrib_hash ||= Hash.new do |h,k|
        h[k.to_sym] = if(cached = (redrecord_redis_cache[k.to_s] unless new_record?))
          Redrecord.is_marshalled?(cached) ? Marshal.load(cached) : cached
        else
          send("#{k}_without_cache")
        end
      end
    end

    def attribs_with_cached_fields
      attributes.merge(cached_fields)
    end

    def cached_fields
      self.class.redrecord_cached_fields.inject({}) {|hsh,field| hsh[field] = send(field) ; hsh }
    end

  end
  
end
