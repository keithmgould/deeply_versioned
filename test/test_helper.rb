require 'test/unit'
require 'rubygems'

# gem install redgreen for colored test output
begin require 'redgreen'; rescue LoadError; end

require File.dirname(__FILE__) + '/boot' unless defined?(ActiveRecord)

class Test::Unit::TestCase
  protected
  def assert_respond_to_all object, methods
    methods.each do |method|
      [method.to_s, method.to_sym].each { |m| assert_respond_to object, m }
    end
  end
end