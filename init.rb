require 'redmine'
require 'gitlab_repositories_helper_patch'

Redmine::Plugin.register :redmine_gitlab_adapter do
  name 'Redmine Gitlab Adapter plugin'
  author 'Komatsu Yuji'
  description 'This is a Gitlab Adapter plugin for Redmine'
  version '0.2.0'
  url 'https://www.future.co.jp'
  author_url 'https://www.future.co.jp'
  Redmine::Scm::Base.add "Gitlab"
end
