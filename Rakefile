# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/rails/**/*_test.rb")
end

Rake::TestTask.new("test:rails") do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/rails/**/*_test.rb"].exclude("test/rails/system/**/*_test.rb")
end

Rake::TestTask.new("test:system") do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/rails/system/**/*_test.rb"]
end

desc "Run frontend JS unit tests (node:test)"
task "test:js" do
  Dir.chdir("frontend") { sh "node --test" }
end

task default: [:test, "test:rails"]

desc "Run StandardRB lint check"
task :lint do
  sh "bundle exec standardrb"
end

desc "Run bundler-audit security check"
task :security do
  sh "bundle exec bundle-audit check --update"
end

desc "Run RubyCritic code quality analysis"
task :rubycritic do
  sh "bundle exec rubycritic lib/sentiero --no-browser --format json --path tmp/rubycritic"
end
