require 'redmine/scm/adapters/gitlab_adapter'

class Repository::Gitlab < Repository
  validates_presence_of :url, :password
  validates_format_of :url, :with => %r{\A(http|https):\/\/.+}i
  safe_attributes 'root_url', 'report_last_commit'
  validates_format_of :root_url, :allow_blank => true, :with => %r{\A(http|https):\/\/.+}i
  validate :validate_root_url
  after_validation :set_root_url

  def validate_root_url
    unless root_url.blank?
      errors.add(:base, l(:field_root_url) + ' ' + l('activerecord.errors.messages.invalid')) unless url.start_with?(root_url)
    end
  end

  def set_root_url
    if !self.url.blank? && self.root_url.blank?
      uri = URI.parse(self.url)
      uri.path = ''
      self.root_url = uri.to_s
    end
    self.root_url = self.root_url.chomp('/')
  end

  def self.scm_adapter_class
    Redmine::Scm::Adapters::GitlabAdapter
  end

  def self.scm_name
    'Gitlab'
  end

  def report_last_commit
    return false if extra_info.nil?
    v = extra_info["extra_report_last_commit"]
    return false if v.nil?
    v.to_s != '0'
  end

  def report_last_commit=(arg)
    merge_extra_info "extra_report_last_commit" => arg
  end

  def supports_directory_revisions?
    true
  end

  def supports_revision_graph?
    true
  end

  def repo_log_encoding
    'UTF-8'
  end

  # Returns the identifier for the given gitlab changeset
  def self.changeset_identifier(changeset)
    changeset.scmid
  end

  # Returns the readable identifier for the given gitlab changeset
  def self.format_changeset_identifier(changeset)
    changeset.revision[0, 8]
  end

  def branches
    scm.branches
  end

  def tags
    scm.tags
  end

  def default_branch
    scm.default_branch
  rescue => e
    logger.error "gitlab: error during get default branch: #{e.message}"
    nil
  end

  def find_changeset_by_name(name)
    if name.present?
      changesets.find_by(:revision => name.to_s) ||
        changesets.where('scmid LIKE ?', "#{name}%").first
    end
  end

  def scm_entries(path=nil, identifier=nil)
    scm.entries(path, identifier, :report_last_commit => report_last_commit)
  end
  protected :scm_entries

  def fetch_changesets
    scm_brs = branches
    return if scm_brs.nil? || scm_brs.empty?

    h1 = extra_info || {}
    h  = h1.dup
    h["last_committed_date"] ||= ""

    h["db_consistent"]  ||= {}
    if ! changesets.exists?
      h["db_consistent"]["ordering"] = 1
      merge_extra_info(h)
      self.save
    elsif ! h["db_consistent"].has_key?("ordering")
      h["db_consistent"]["ordering"] = 0
      merge_extra_info(h)
      self.save
    end

    save_revisions(nil, nil, h['last_committed_date'])
  end

  def save_revisions(prev_db_heads, repo_heads, last_committed_date)
    h = {}
    opts = {}
    opts[:last_committed_date] = last_committed_date
    opts[:all] = true

    revisions = scm.revisions('', nil, nil, opts)
    return if revisions.blank?

    limit = 100
    offset = 0
    revisions_copy = revisions.clone # revisions will change
    while offset < revisions_copy.size
      scmids = revisions_copy.slice(offset, limit).map{|x| x.scmid}
      recent_changesets_slice = changesets.where(:scmid => scmids)
      # Subtract revisions that redmine already knows about
      recent_revisions = recent_changesets_slice.map{|c| c.scmid}
      revisions.reject!{|r| recent_revisions.include?(r.scmid)}
      offset += limit
    end
    revisions.each do |rev|
      transaction do
        # There is no search in the db for this revision, because above we ensured,
        # that it's not in the db.
        save_revision(rev)
      end
    end

    if revisions_copy.size > 0
      h["last_committed_date"] = revisions_copy.last.time.utc.strftime("%FT%TZ")
    end

    if revisions.size > 0
      h["last_committed_date"] = revisions.last.time.utc.strftime("%FT%TZ")
    end

    merge_extra_info(h)
    save(:validate => false)
  end
  private :save_revisions

  def save_revision(rev)
    parents = (rev.parents || []).collect{|rp| find_changeset_by_name(rp)}.compact
    changeset = Changeset.create(
              :repository   => self,
              :revision     => rev.identifier,
              :scmid        => rev.scmid,
              :committer    => rev.author,
              :committed_on => rev.time,
              :comments     => rev.message,
              :parents      => parents
              )
    unless changeset.new_record?
      rev.paths.each { |change| changeset.create_change(change) }
    end
    changeset
  end
  private :save_revision

  def latest_changesets(path, rev, limit = 10)
    revisions = scm.revisions(path, nil, rev, :limit => limit, :all => false)
    return [] if revisions.nil? || revisions.empty?
    changesets.where(:scmid => revisions.map {|c| c.scmid}).to_a
  end

  def clear_extra_info_of_changesets
    return if extra_info.nil?
    v = extra_info["extra_report_last_commit"]
    write_attribute(:extra_info, nil)
    h = {}
    h["extra_report_last_commit"] = v
    merge_extra_info(h)
    save(:validate => false)
  end
  private :clear_extra_info_of_changesets

  def clear_changesets
    super
    clear_extra_info_of_changesets
  end
  private :clear_changesets

end
