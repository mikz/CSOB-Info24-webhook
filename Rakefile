# frozen_string_literal: true

require 'dotenv/tasks'

require 'json'
require 'net/http'

task console: :dotenv do
  require 'pry'
  ARGV.clear
  Pry.start
end

task :test do
  require_relative 'csob'

  CSOB::Transaction.extract(open('test.txt').read).each do |t|
    puts t.to_json
  end
end
