require 'active_model'
require 'active_support/core_ext/module/aliasing'
require "#{File.dirname(__FILE__)}/../lib/redrecord"
require 'test/unit'
require 'ostruct'
require 'redis'
require "#{File.dirname(__FILE__)}/test_helper"

class TestRedrecord < Test::Unit::TestCase
  def setup
    $redis.flushdb
    Redrecord.redis = $redis
    Redrecord.enabled = true
    @user = TestUser.new(1, 'John', 'Smith')
    $saved = {}
  end
  
  def test_cached_string_attribute_save
    # start with a blank slate and save the record
    assert_equal({}, $redis.hgetall('TestUser:1'))
    assert_nil @user.recalculated
    @user.save
    
    # It should now be saved in redis
    assert @user.recalculated
    assert_equal 'John Smith', $redis.hget('TestUser:1', 'full_name')
    
    # different object should get the value straight of redis
    u2 = TestUser.new(1)
    assert_equal 'John Smith', u2.full_name
    assert_nil u2.recalculated
  end

  def test_cached_nil_attribute_save
    @user.save
    assert_equal Marshal.dump(nil), $redis.hget('TestUser:1', 'nil')
    u2 = TestUser.new(1, 'John', 'Smith')
    assert_nil u2.nil
  end
  
  def test_number
    @user.save
    assert_equal '12345', $redis.hget('TestUser:1', 'number')
    assert_equal 12345, @user.number_with_cache
  end

  def test_invalidation_on_save
    @user.save
    @user.first_name = 'Bob'
    @user.save
    
    assert_equal 'Bob Smith', $redis.hget('TestUser:1', 'full_name')
    
    u2 = TestUser.new(1)
    assert_equal 'Bob Smith', u2.full_name
    assert_nil u2.recalculated
  end
  
  def test_invalidation_on_delete
    @user.save
    assert_equal 'John Smith', $redis.hget('TestUser:1', 'full_name')
    @user.destroy
    assert_equal({}, $redis.hgetall('TestUser:1'))
  end

  def test_invalidation_on_rollback
    @user.save_with_rollback
    assert_equal({}, $redis.hgetall('TestUser:1'))
  end
  
  def test_invalidation_on_association_create
    # Create two groups which are attached to the user
    TestGroup.new(1, 'users', @user).save
    TestGroup.new(2, 'admins', @user).save
    #@user.save
    
    # Now a fresh user record should get the answer out of cache
    u2 = TestUser.new(1)
    assert_equal ['admins', 'users'], u2.group_names
    assert_nil u2.recalculated
  end

  def test_invalidation_on_association
    # Create two groups which are attached to the user
    TestGroup.new(1, 'users', @user).save
    g = TestGroup.new(2, 'admins', @user).save
    @user.save
    
    # Removing a group should also refresh the cache
    g.destroy
    assert_equal ['users'], TestUser.new(1).group_names
  end
  
  def test_attribs
    assert_equal({
        :nil         => nil,
        :group_names => [],
        :valid?      => true,
        :number      => 12345,
        :full_name   => 'John Smith'},
      @user.cached_fields)
  end

  def test_cached_fields
    assert_equal({
        :first_name  => 'John',
        :last_name   => 'Smith',
        :id          => 1,
        :nil         => nil,
        :group_names => [],
        :valid?      => true,
        :number      => 12345,
        :full_name   => 'John Smith'},
      @user.attribs_with_cached_fields)
  end

  def test_write_only_mode
    Redrecord.write_only = true
    @user.save
    assert_equal 'John Smith', $redis.hget('TestUser:1', 'full_name')
    
    # different object should not get the value from redis
    u2 = TestUser.new(1, 'Bob', 'Smith')
    assert_equal 'Bob Smith', u2.full_name
    assert u2.recalculated    
  end

  def test_disabled_mode
    Redrecord.enabled = nil
    @user.save
    assert_nil $redis.hget('TestUser:1', 'full_name')
  end

  def test_question_marked_method
    @user.save
    u2 = TestUser.new(1, 'Bob', 'Smith')
    assert_equal true, u2.valid?
    assert !u2.recalculated    
  end
  
  def test_disable_due_to_exception
    Redrecord.redis = nil
    old = $stderr ; $stderr = StringIO.new
    @user.save
    $stderr = old
    assert_equal false, Redrecord.enabled
  end

  def test_verify_ok
    @user.save
    assert_equal ["full_name", "nil", "group_names", "valid?", "number"].sort, @user.verify_cache!.sort
  end

  def test_verify_fail
    @user.save
    assert_raises RuntimeError do
      @user.first_name = 'Derp'
      @user.verify_cache!
    end
  end  
  
  def test_inherited_invalidations
    assert_equal [:user], TestGroup.redrecord_invalidation_fields
    assert_equal [:user], TestDeepGroup.redrecord_invalidation_fields
    assert_equal [], TestModel.redrecord_invalidation_fields
  end

end
