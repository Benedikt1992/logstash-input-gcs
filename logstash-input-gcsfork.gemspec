Gem::Specification.new do |s|
  s.name          = 'logstash-input-gcsfork'
  s.version       = '2.0.10'
  s.licenses      = ['Apache-2.0']
  s.summary       = 'This example input streams a string at a definable interval.'
  s.description   = 'This gem is a logstash plugin required to be installed on top of the Logstash core pipeline using $LS_HOME/bin/plugin install gemname. This gem is not a stand-alone program'
  s.homepage      = 'https://github.com/Benedikt1992/logstash-input-gcs'
  s.authors       = ['Benedikt1992']
  s.email         = 'mail@benedikt1992.de'
  s.require_paths = ['lib']

  # Files
  s.files = Dir['lib/**/*','spec/**/*','vendor/**/*','*.gemspec','*.md','CONTRIBUTORS','Gemfile','LICENSE','NOTICE.TXT']
   # Tests
  s.test_files = s.files.grep(%r{^(test|spec|features)/})

  # Special flag to let us know this is actually a logstash plugin
  s.metadata = { "logstash_plugin" => "true", "logstash_group" => "input" }

  # Gem dependencies
  s.add_runtime_dependency "logstash-core-plugin-api", "~> 2.0"
  s.add_runtime_dependency 'logstash-codec-plain'
  s.add_runtime_dependency 'stud', '>= 0.0.22'
  s.add_runtime_dependency 'google-cloud-storage', "~> 1.9"#"~> 0.24" # this is a very old version! Newer versions are not possible due to dependency conflicts with gems required by logstash
  s.add_development_dependency 'logstash-devutils', '>= 0.0.16'
end
