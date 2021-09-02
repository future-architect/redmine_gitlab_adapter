require_dependency 'repositories_helper'

module GitlabRepositoriesHelperPatch

  def self.included(base)
    base.send(:include, InstanceMethods)
  end

  module InstanceMethods
    def gitlab_field_tags(form, repository)
      content_tag('p', form.text_field(:url, :size => 60, :required => true,
                       :disabled => !repository.safe_attribute?('url')) +
      scm_path_info_tag(repository)) +
      content_tag('p', form.password_field(
                          :password, :size => 60, :name => 'ignore',
                          :label => 'API Token', :required => true,
                          :value => ((repository.new_record? || repository.password.blank?) ? '' : ('x'*15)),
                          :onfocus => "this.value=''; this.name='repository[password]';",
                          :onchange => "this.name='repository[password]';")) +
      content_tag('p', form.text_field(:root_url, :size => 60) + gitlab_root_url_tag) +
      content_tag('p', form.check_box(
                          :report_last_commit,
                          :label => l(:label_git_report_last_commit)
                           ))
    end

    def gitlab_root_url_tag
      text = l("text_gitlab_root_url_note", :default => '')
      if text.present?
        content_tag('em', text, :class => 'info')
      else
        ''
      end
    end
  end
end

RepositoriesHelper.send(:include, GitlabRepositoriesHelperPatch)
