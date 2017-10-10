Gem::Specification.new do |s|
  s.name  = "netsuite_endpoint"
  s.version = "0.0.1"

  s.summary = "Cangaroo endpoint for Netsuite"
  s.description = ""

  s.authors = ["Joe Lind"]
  s.email = "joe@shopfollain.com"
  s.homepage = "http://shopfollain.com"

  s.files = ([`git ls-files lib/`.split("\n")]).flatten

  s.test_files = `git ls-files spec/`.split("\n")

  s.add_runtime_dependency 'netsuite'
  s.add_runtime_dependency 'sinatra'
  s.add_runtime_dependency 'tilt'
  s.add_runtime_dependency 'tilt-jbuilder'
end
