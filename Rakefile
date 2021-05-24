#!/usr/bin/env rake
require "bundler/gem_tasks"

require 'rake/testtask'
require 'rake/clean'

require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)
task :default => [:spec, :build]

# 1. update Changelog and lib/serverengine/version.rb
# 2. bundle && bundle exec rake build:all
# 3. release 3 packages built on pkg/ directory
namespace :build do
  desc 'Build gems for all platforms'
  task :all do
    Bundler.with_clean_env do
      %w[ruby x86-mingw32 x64-mingw32].each do |name|
        ENV['GEM_BUILD_FAKE_PLATFORM'] = name
        Rake::Task["build"].execute
      end
    end
  end
end

