
# WARNING: The database specified here will be CLEARED of ALL DATA
$redis = Redis.new(:host => 'localhost', :port => 6379, :db => 15)

class TestModel
  extend ActiveModel::Callbacks

  define_model_callbacks :save, :destroy, :commit, :rollback
  
  include Redrecord::Model
  
  def save
    run_callbacks :commit do
      run_callbacks :save do
        $saved[redrecord_key] = self
      end
    end
  end
  def destroy
    run_callbacks :commit do
      run_callbacks :destroy do
        $saved.delete(redrecord_key)
      end
    end
  end
  def save_with_rollback
    run_callbacks :rollback do
      run_callbacks :save do
      end
    end
  end
  def new_record?
    !$saved[redrecord_key]
  end
  def self.table_name
    self.to_s.split('::').last
  end
  def attributes
    instance_variables.map {|var| var.to_s.gsub(/^@/,'').to_sym }.inject({}) {|hsh,var| hsh[var] = send(var) ; hsh}
  end
end

class TestGroup < TestModel
  attr_accessor :id, :name, :user
  def initialize(id, name=nil, user=nil)
    @id, @name, @user = id, name, user
  end
  invalidate_cache_on :user
end

class TestUser < TestModel
  attr_accessor :first_name, :last_name, :id, :recalculated
  def initialize(id, first_name=nil, last_name=nil)
    @id, @first_name, @last_name = id, first_name, last_name
  end
  
  redis_cache do
    def full_name
      @recalculated = true
      "#{first_name} #{last_name}"
    end
    def nil
      nil
    end
    def group_names
      $saved.values.select {|v| TestGroup===v && v.user.id == self.id }.map(&:name).sort
    end
    def valid?
      true
    end
  end
end
