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
        :full_name   => 'John Smith'},
      @user.attribs_with_cached_fields)
  end

  
end
