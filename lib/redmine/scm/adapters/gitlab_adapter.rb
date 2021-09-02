require 'redmine/scm/adapters/abstract_adapter'
require 'uri'
require 'no_proxy_fix'

module Redmine
  module Scm
    module Adapters
      class GitlabAdapter < AbstractAdapter

        # Git executable name
        GITLAB_BIN = "gitlab"
        # Repositories created after 2020 may have a default branch of
        # "main" instead of "master"
        GITLAB_DEFAULT_BRANCH_NAMES = %w[main master].freeze

        PER_PAGE = 50
        MAX_PAGES = 10

        class GitlabBranch < Branch
          attr_accessor :is_default
        end

        class << self
          def client_command
            @@bin    ||= GITLAB_BIN
          end

          def sq_bin
            @@sq_bin ||= shell_quote_command
          end

          def client_version
            @@client_version ||= (scm_command_version || [])
          end

          def client_available
            !client_version.empty?
          end

          def scm_command_version
            scm_version = Gitlab::VERSION
            if m = scm_version.match(%r{\A(.*?)((\d+\.)+\d+)})
              m[2].scan(%r{\d+}).collect(&:to_i)
            end
          end
        end

        def initialize(url, root_url=nil, login=nil, password=nil, path_encoding=nil)
          super

          ## Get gitlab project
          @project = url.sub(root_url, '').sub(/^\//, '').sub(/\.git$/, '')

          ## Set Gitlab endpoint and token
          Gitlab.endpoint = root_url + '/api/v4'
          Gitlab.private_token = password

          ## Set proxy
          proxy = URI.parse(url).find_proxy
          unless proxy.nil?
            Gitlab.http_proxy(proxy.host, proxy.port, proxy.user, proxy.password)
          end
        end

        def info
          Info.new(:root_url => root_url, :lastrev => lastrev('',nil))
        rescue
          nil
        end

        def branches
          return @branches if @branches
          @branches = []
          1.step do |i|
            gitlab_branches = Gitlab.branches(@project, {page: i, per_page: PER_PAGE})
            break if gitlab_branches.length == 0
            gitlab_branches.each do |gitlab_branche|
              bran = GitlabBranch.new(gitlab_branche.name)
              bran.revision = gitlab_branche.commit.id
              bran.scmid = gitlab_branche.commit.id
              bran.is_default = gitlab_branche.default
              @branches << bran
            end
          end
          @branches.sort!
        rescue Gitlab::Error::Error
          nil
        end

        def tags
          return @tags if @tags
          @tags = []
          1.step do |i|
            gitlab_tags = Gitlab.tags(@project, {page: i, per_page: PER_PAGE})
            break if gitlab_tags.length == 0
            gitlab_tags.each do |gitlab_tag|
              @tags << gitlab_tag.name
            end
          end
          @tags
        rescue Gitlab::Error::Error
          nil
        end

        def default_branch
          return if branches.blank?

          (
            branches.detect(&:is_default) ||
            branches.detect {|b| GIT_DEFAULT_BRANCH_NAMES.include?(b.to_s)} ||
            branches.first
          ).to_s
        end

        def entry(path=nil, identifier=nil)
          parts = path.to_s.split(%r{[\/\\]}).select {|n| !n.blank?}
          search_path = parts[0..-2].join('/')
          search_name = parts[-1]
          if search_path.blank? && search_name.blank?
            # Root entry
            Entry.new(:path => '', :kind => 'dir')
          else
            # Search for the entry in the parent directory
            es = entries(search_path, identifier,
                         options = {:report_last_commit => false})
            es ? es.detect {|e| e.name == search_name} : nil
          end
        end

        def entries(path=nil, identifier=nil, options={})
          path ||= ''
          identifier = 'HEAD' if identifier.nil?

          entries = Entries.new
          1.step do |i|
            files = Gitlab.tree(@project, {path: path, ref: identifier, page: i, per_page: PER_PAGE})
            break if files.length == 0

            files.each do |file|
              full_path = path.empty? ? file.name : "#{path}/#{file.name}"
              size = nil
              unless (file.type == "tree")
                gitlab_get_file = Gitlab.get_file(@project, full_path, identifier)
                size = gitlab_get_file.size
              end
              entries << Entry.new({
                :name => file.name.dup,
                :path => full_path.dup,
                :kind => (file.type == "tree") ? 'dir' : 'file',
                :size => (file.type == "tree") ? nil : size,
                :lastrev => options[:report_last_commit] ? lastrev(full_path, identifier) : Revision.new
              }) unless entries.detect{|entry| entry.name == file.name}
            end
          end
          entries.sort_by_name
        rescue Gitlab::Error::Error
          nil
        end

        def lastrev(path, rev)
          return nil if path.nil?
          gitlab_commits = Gitlab.commits(@project, {path: path, ref_name: rev, per_page: 1})
          gitlab_commits.each do |gitlab_commit|
            return Revision.new({
              :identifier => gitlab_commit.id,
              :scmid      => gitlab_commit.id,
              :author     => gitlab_commit.author_name,
              :time       => Time.parse(gitlab_commit.committed_date),
              :message    => nil,
              :paths      => nil
            })
          end
          return nil
        rescue Gitlab::Error::Error
          nil
        end

        def revisions(path, identifier_from, identifier_to, options={})
          revs = Revisions.new
          per_page = PER_PAGE
          per_page = options[:limit].to_i if options[:limit]
          all = false
          all = options[:all] if options[:all]
          since = ''
          since = options[:last_committed_date] if options[:last_committed_date]

          if all
            ## STEP 1: Seek start_page
            start_page = 1
            0.step do |i|
              start_page = i * MAX_PAGES + 1
              gitlab_commits = Gitlab.commits(@project, {all: true, since: since, page: start_page, per_page: per_page})
              if gitlab_commits.length < per_page
                start_page = start_page - MAX_PAGES if i > 0
                break
              end
            end

            ## Step 2: Get the commits from start_page
            start_page.step do |i|
              gitlab_commits = Gitlab.commits(@project, {all: true, since: since, page: i, per_page: per_page})
              break if gitlab_commits.length == 0
              gitlab_commits.each do |gitlab_commit|
                files=[]
                gitlab_commit_diff = Gitlab.commit_diff(@project, gitlab_commit.id)
                gitlab_commit_diff.each do |commit_diff|
                  if commit_diff.new_file
                    files << {:action => 'A', :path => commit_diff.new_path}
                  elsif commit_diff.deleted_file
                    files << {:action => 'D', :path => commit_diff.new_path}
                  elsif commit_diff.renamed_file
                    files << {:action => 'D', :path => commit_diff.old_path}
                    files << {:action => 'A', :path => commit_diff.new_path}
                  else
                    files << {:action => 'M', :path => commit_diff.new_path}
                  end
                end
                revision = Revision.new({
                  :identifier => gitlab_commit.id,
                  :scmid      => gitlab_commit.id,
                  :author     => gitlab_commit.author_name,
                  :time       => Time.parse(gitlab_commit.committed_date),
                  :message    => gitlab_commit.message,
                  :paths      => files,
                  :parents    => gitlab_commit.parent_ids.dup
                })
                revs << revision
              end
            end
          else
            gitlab_commits = Gitlab.commits(@project, {path: path, ref_name: identifier_to, per_page: per_page})
            gitlab_commits.each do |gitlab_commit|
              revision = Revision.new({
                :identifier => gitlab_commit.id,
                :scmid      => gitlab_commit.id,
                :author     => gitlab_commit.author_name,
                :time       => Time.parse(gitlab_commit.committed_date),
                :message    => gitlab_commit.message,
                :paths      => [],
                :parents    => gitlab_commit.parent_ids.dup
              })
              revs << revision
            end
          end
          revs.sort! do |a, b|
            a.time <=> b.time
          end
          revs
        rescue Gitlab::Error::Error => e
          err_msg = "gitlab log error: #{e.message}"
          logger.error(err_msg)
        end

        def diff(path, identifier_from, identifier_to=nil)
          path ||= ''
          diff = []

          gitlab_diffs = []
          if identifier_to.nil?
            gitlab_diffs = Gitlab.commit_diff(@project, identifier_from)
          else
            gitlab_diffs = Gitlab.compare(@project, identifier_to, identifier_from).diffs
          end

          gitlab_diffs.each do |gitlab_diff|
            if identifier_to.nil? && path.length > 0
              next unless gitlab_diff.new_path == path
            end
            if gitlab_diff.kind_of?(Hash)
              renamed_file = gitlab_diff["renamed_file"]
              new_path = gitlab_diff["new_path"]
              old_path = gitlab_diff["old_path"]
              gitlab_diff_diff = gitlab_diff["diff"]
            else
              renamed_file = gitlab_diff.renamed_file
              new_path = gitlab_diff.new_path
              old_path = gitlab_diff.old_path
              gitlab_diff_diff = gitlab_diff.diff
            end

            if renamed_file
              filecontent = cat(new_path, identifier_from)
              if filecontent.nil?
                diff << "diff"
                diff << "--- a/#{old_path}"
                diff << "+++ b/#{new_path}"
              else
                diff << "diff"
                diff << "--- a/#{old_path}"
                diff << "+++ /dev/null"
                diff << "@@ -1,2 +0,0 @@"
                filecontent.split("\n").each do |line|
                  diff << "-#{line}"
                end
                diff << "diff"
                diff << "--- /dev/null"
                diff << "+++ b/#{new_path}"
                diff << "@@ -0,0 +1,2 @@"
                filecontent.split("\n").each do |line|
                  diff << "+#{line}"
                end
              end
            else
              diff << "diff"
              diff << "--- a/#{old_path}"
              diff << "+++ b/#{new_path}"
              diff << gitlab_diff_diff.split("\n")
            end
          end
          diff.flatten!
          diff.deep_dup
        rescue Gitlab::Error::Error
          nil
        end

        def annotate(path, identifier=nil)
          identifier = 'HEAD' if identifier.blank?
          blame = Annotate.new
          gitlab_get_file_blame = Gitlab.get_file_blame(@project, path, identifier)
          gitlab_get_file_blame.each do |file_blame|
            file_blame.lines.each do |line|
              blame.add_line(line, Revision.new(
                                    :identifier => file_blame.commit.id,
                                    :revision   => file_blame.commit.id,
                                    :scmid      => file_blame.commit.id,
                                    :author     => file_blame.commit.author_name
                                    ))
            end
          end
          blame
        rescue Gitlab::Error::Error
          nil
        end

        def cat(path, identifier=nil)
          identifier = 'HEAD' if identifier.nil?
          Gitlab.file_contents(@project, path, identifier)
        rescue Gitlab::Error::Error
          nil
        end

        class Revision < Redmine::Scm::Adapters::Revision
          # Returns the readable identifier
          def format_identifier
            identifier[0,8]
          end
        end

        def valid_name?(name)
          true
        end

      end
    end
  end
end
