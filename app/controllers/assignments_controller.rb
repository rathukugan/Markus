require 'base64'


class AssignmentsController < ApplicationController
  before_filter      :authorize_only_for_admin,
                     except: [:deletegroup,
                              :delete_rejected,
                              :disinvite_member,
                              :invite_member,
                              :creategroup,
                              :join_group,
                              :decline_invitation,
                              :index,
                              :student_interface,
                              :update_collected_submissions,
                              :render_feedback_file,
                              :peer_review]

  before_filter      :authorize_for_student,
                     only: [:student_interface,
                            :deletegroup,
                            :delete_rejected,
                            :disinvite_member,
                            :invite_member,
                            :creategroup,
                            :join_group,
                            :decline_invitation,
                            :peer_review]

  before_filter      :authorize_for_user,
                     only: [:index, :render_feedback_file]

  auto_complete_for  :assignment,
                     :name

  # Copy of API::AssignmentController without the id and order changed
  # to put first the 4 required fields
  DEFAULT_FIELDS = [:short_identifier, :description, :repository_folder,
                    :due_date, :message, :group_min, :group_max, :tokens_per_period,
                    :allow_web_submits, :student_form_groups, :remark_due_date,
                    :remark_message, :assign_graders_to_criteria, :enable_test,
                    :enable_student_tests, :allow_remarks, :display_grader_names_to_students,
                    :group_name_autogenerated, :is_hidden,
                    :vcs_submit, :has_peer_review]

  # Publicly accessible actions ---------------------------------------

  def render_feedback_file
    @feedback_file = FeedbackFile.find(params[:feedback_file_id])

    # Students can use this action only, when marks have been released
    if current_user.student? &&
        (@feedback_file.submission.grouping.membership_status(current_user).nil? ||
         !@feedback_file.submission.get_latest_result.released_to_students)
      flash_message(:error, t('feedback_file.error.no_access',
                              feedback_file_id: @feedback_file.id))
      head :forbidden
      return
    end

    if @feedback_file.mime_type.start_with? 'image'
      content = Base64.encode64(@feedback_file.file_content)
    else
      content = @feedback_file.file_content
    end

    send_data content,
              type: @feedback_file.mime_type,
              filename: @feedback_file.filename,
              disposition: 'inline'
  end

  def student_interface
    assignment = Assignment.find(params[:id])
    @assignment = assignment.is_peer_review? ? assignment.parent_assignment : assignment
    if @assignment.is_hidden
      render 'shared/http_status',
             formats: [:html],
             locals: {
               code: '404',
               message: HttpStatusHelper::ERROR_CODE['message']['404']
             },
             status: 404,
             layout: false
      return
    end

    @student = current_user
    @grouping = @student.accepted_grouping_for(@assignment.id)
    @penalty = SubmissionRule.find_by_assignment_id(@assignment.id)
    @enum_penalty = Period.where(submission_rule_id: @penalty.id).sort

    if @student.section &&
       !@student.section.section_due_date_for(@assignment.id).nil?
      @due_date =
        @student.section.section_due_date_for(@assignment.id).due_date
    end
    if @due_date.nil?
      @due_date = @assignment.due_date
    end
    if @student.has_pending_groupings_for?(@assignment.id)
      @pending_grouping = @student.pending_groupings_for(@assignment.id)
    end
    if @grouping.nil?
      if @assignment.group_max == 1 && !@assignment.scanned_exam
        begin
          # fix for issue #627
          # currently create_group_for_working_alone_student only returns false
          # when saving a grouping throws an exception
          unless @student.create_group_for_working_alone_student(@assignment.id)
            # if create_group_for_working_alone_student returned false then the student
            # must have an ( empty ) existing grouping that he is not a member of.
            # we must delete this grouping for the transaction to succeed.
            Grouping.find_by_group_id_and_assignment_id( Group.find_by_group_name(@student.user_name), @assignment.id).destroy
          end
        rescue RuntimeError => @error
          flash_message(:error, 'Error')
        end
        redirect_to action: 'student_interface', id: @assignment.id
      else
        if @assignment.scanned_exam
          flash_now(:notice, t('assignments.scanned_exam.under_review'))
        end
        render :student_interface
      end
    else
      # We look for the information on this group...
      # The members
      @studentmemberships = @grouping.student_memberships
      # The group name
      @group = @grouping.group
      # The inviter
      @inviter = @grouping.inviter

      # Look up submission information
      repo = @grouping.group.repo
      @revision = repo.get_latest_revision
      @revision_identifier = @revision.revision_identifier

      @last_modified_date = @grouping.assignment_folder_last_modified_date
      @num_submitted_files = @grouping.number_of_submitted_files
      @num_missing_assignment_files = @grouping.missing_assignment_files.length
      repo.close
    end
  end

  def peer_review
    assignment = Assignment.find(params[:id])
    @assignment = assignment.is_peer_review? ? assignment : assignment.pr_assignment
    if @assignment.nil? || @assignment.is_hidden
      render 'shared/http_status',
             formats: [:html],
             locals: {
                 code: '404',
                 message: HttpStatusHelper::ERROR_CODE['message']['404']
             },
             status: 404,
             layout: false
      return
    end

    @student = current_user
    @grouping = @student.accepted_grouping_for(@assignment.id)
    @penalty = @assignment.submission_rule
    @enum_penalty = Period.where(submission_rule_id: @penalty.id).sort

    @prs = @student.grouping_for(@assignment.parent_assignment.id).
        peer_reviews.where(results: { released_to_students: true })

    if @student.section &&
        !@student.section.section_due_date_for(@assignment.id).nil?
      @due_date =
          @student.section.section_due_date_for(@assignment.id).due_date
    end
    if @due_date.nil?
      @due_date = @assignment.due_date
    end
    if @assignment.past_all_collection_dates?
      flash_now(:notice, t('browse_submissions.grading_can_begin'))
    else
      if @assignment.section_due_dates_type
        section_due_dates = Hash.new
        now = Time.zone.now
        Section.all.each do |section|
          collection_time = @assignment.submission_rule
                                .calculate_collection_time(section)
          collection_time = now if now >= collection_time
          if section_due_dates[collection_time].nil?
            section_due_dates[collection_time] = Array.new
          end
          section_due_dates[collection_time].push(section.name)
        end
        section_due_dates.each do |collection_time, sections|
          sections = sections.join(', ')
          if(collection_time == now)
            flash_now(:notice, t('browse_submissions.grading_can_begin_for_sections',
                                 sections: sections))
          else
            flash_now(:notice, t('browse_submissions.grading_can_begin_after_for_sections',
                                 time: l(collection_time, format: :long_date),
                                 sections: sections))
          end
        end
      else
        collection_time = @assignment.submission_rule.calculate_collection_time
        flash_now(:notice, t('browse_submissions.grading_can_begin_after',
                             time: l(collection_time, format: :long_date)))
      end
    end
  end

  # Displays "Manage Assignments" page for creating and editing
  # assignment information
  def index
    @marking_schemes = MarkingScheme.all
    @default_fields = DEFAULT_FIELDS
    if current_user.student?
      @grade_entry_forms = GradeEntryForm.where(is_hidden: false).order(:id)
      @assignments = Assignment.where(is_hidden: false).order(:id)
      #get the section of current user
      @section = current_user.section
      # get results for assignments for the current user
      @a_id_results = Hash.new()
      @assignments.each do |a|
        if current_user.has_accepted_grouping_for?(a)
          grouping = current_user.accepted_grouping_for(a)
          if grouping.has_submission?
            submission = grouping.current_submission_used
            if submission.has_remark? && submission.remark_result.released_to_students
              @a_id_results[a.id] = submission.remark_result
            elsif submission.has_result? && submission.get_original_result.released_to_students
              @a_id_results[a.id] = submission.get_original_result
            end
          end
        end
      end

      # Get the grades for grade entry forms for the current user
      @g_id_entries = Hash.new()
      @grade_entry_forms.each do |g|
        grade_entry_student = g.grade_entry_students.find_by_user_id(
                                    current_user.id )
        if !grade_entry_student.nil? &&
             grade_entry_student.released_to_student
          @g_id_entries[g.id] = grade_entry_student
        end
      end

      render :student_assignment_list, layout: 'assignment_content'
    elsif current_user.ta?
      @grade_entry_forms = GradeEntryForm.order(:id)
      @assignments = Assignment.includes(:submission_rule).order(:id)
      render :grader_index, layout: 'assignment_content'
    else
      @grade_entry_forms = GradeEntryForm.order(:id)
      @assignments = Assignment.includes(:submission_rule).order(:id)
      render :index, layout: 'assignment_content'
    end
  end

  # Called on editing assignments (GET)
  def edit
    @assignment = Assignment.find_by_id(params[:id])
    @past_date = @assignment.section_names_past_due_date
    @assignments = Assignment.all
    @clone_assignments = Assignment.where(allow_web_submits: false)
                                   .where.not(id: @assignment.id)
                                   .order(:id)
    @sections = Section.all

    unless @past_date.nil? || @past_date.empty?
      flash_now(:notice, t('past_due_date_notice') + @past_date.join(', '))
    end

    # build section_due_dates for each section that doesn't already have a due date
    Section.all.each do |s|
      unless SectionDueDate.find_by_assignment_id_and_section_id(@assignment.id, s.id)
        @assignment.section_due_dates.build(section: s)
      end
    end
    @section_due_dates = @assignment.section_due_dates
                                    .sort_by { |s| [SectionDueDate.due_date_for(s.section, @assignment), s.section.name] }
  end

  # Called when editing assignments form is submitted (PUT).
  def update
    @assignment = Assignment.find_by_id(params[:id])
    @assignments = Assignment.all
    @sections = Section.all
    @clone_assignments = Assignment.where(allow_web_submits: false)
                                   .where.not(id: @assignment.id)
                                   .order(:id)

    begin
      @assignment.transaction do
        @assignment = process_assignment_form(@assignment)
      end
    rescue SubmissionRule::InvalidRuleType => e
      @assignment.errors.add(:base, t('assignment.error', message: e.message))
      flash_message(:error, t('assignment.error', message: e.message))
      render :edit, id: @assignment.id
      return
    end

    if @assignment.save
      flash_message(:success, I18n.t('assignment.update_success'))
      redirect_to action: 'edit', id: params[:id]
    else
      render :edit, id: @assignment.id
    end
  end

  # Called in order to generate a form for creating a new assignment.
  # i.e. GET request on assignments/new
  def new
    @assignments = Assignment.all
    @assignment = Assignment.new
    if params[:scanned].present?
      @assignment.scanned_exam = true
    end
    @clone_assignments = Assignment.where(allow_web_submits: false)
                                   .order(:id)
    @sections = Section.all
    @assignment.build_submission_rule
    @assignment.build_assignment_stat

    # build section_due_dates for each section
    Section.all.each { |s| @assignment.section_due_dates.build(section: s)}
    @section_due_dates = @assignment.section_due_dates
                                    .sort_by { |s| s.section.name }

    # set default value if web submits are allowed
    @assignment.allow_web_submits =
        !MarkusConfigurator.markus_config_repository_external_submits_only?
    render :new
  end

  # Called after a new assignment form is submitted.
  def create
    @assignment = Assignment.new
    @assignment.build_assignment_stat
    @assignment.build_submission_rule
    @assignment.transaction do
      begin
        @assignment = process_assignment_form(@assignment)
        @assignment.token_start_date = @assignment.due_date
        @assignment.token_period = 1
      rescue Exception, RuntimeError => e
        @assignment.errors.add(:base, e.message)
      end
      unless @assignment.save
        @assignments = Assignment.all
        @sections = Section.all
        @clone_assignments = Assignment.where(allow_web_submits: false)
                                       .order(:id)
        render :new
        return
      end
      if params[:persist_groups_assignment]
        @assignment.clone_groupings_from(params[:persist_groups_assignment])
      end
      if @assignment.save
        flash_message(:success, I18n.t('assignment.create_success'))
      end
    end
    redirect_to action: 'edit', id: @assignment.id
  end

  # Methods for the student interface

  def join_group
    @assignment = Assignment.find(params[:id])
    @grouping = Grouping.find(params[:grouping_id])
    @user = Student.find(session[:uid])
    @user.join(@grouping.id)
    m_logger = MarkusLogger.instance
    m_logger.log("Student '#{@user.user_name}' joined group '#{@grouping.group.group_name}'" +
                 '(accepted invitation).')
    redirect_to action: 'student_interface', id: params[:id]
  end

  def decline_invitation
    @assignment = Assignment.find(params[:id])
    @grouping = Grouping.find(params[:grouping_id])
    @user = Student.find(session[:uid])
    @grouping.decline_invitation(@user)
    m_logger = MarkusLogger.instance
    m_logger.log("Student '#{@user.user_name}' declined invitation for group '" +
                 "#{@grouping.group.group_name}'.")
    redirect_to action: 'student_interface', id: params[:id]
  end

  def creategroup
    @assignment = Assignment.find(params[:id])
    @student = @current_user
    m_logger = MarkusLogger.instance
    begin
      # We do not allow group creations by students after the due date
      # and the grace period for an assignment
      if @assignment.past_collection_date?(@student.section)
        raise I18n.t('create_group.fail.due_date_passed')
      end
      if !@assignment.student_form_groups ||
           @assignment.invalid_override
        raise I18n.t('create_group.fail.not_allow_to_form_groups')
      end
      if @student.has_accepted_grouping_for?(@assignment.id)
        raise I18n.t('create_group.fail.already_have_a_group')
      end
      if params[:workalone]
        if @assignment.group_min != 1
          raise I18n.t('create_group.fail.can_not_work_alone',
                        group_min: @assignment.group_min)
        end
        # fix for issue #627
        # currently create_group_for_working_alone_student only returns false
        # when saving a grouping throws an exception
        unless @student.create_group_for_working_alone_student(@assignment.id)
          # if create_group_for_working_alone_student returned false then the student
          # must have an ( empty ) existing grouping that he is not a member of.
          # we must delete this grouping for the transaction to succeed.
          Grouping.find_by_group_id_and_assignment_id( Group.find_by_group_name(@student.user_name), @assignment.id).destroy
        end
      else
        @student.create_autogenerated_name_group(@assignment.id)
      end
      m_logger.log("Student '#{@student.user_name}' created group.",
                   MarkusLogger::INFO)
    rescue RuntimeError => e
      flash[:fail_notice] = e.message
      m_logger.log("Failed to create group. User: '#{@student.user_name}', Error: '" +
                   "#{e.message}'.", MarkusLogger::ERROR)
    end
    redirect_to action: 'student_interface', id: @assignment.id
  end

  def deletegroup
    @assignment = Assignment.find(params[:id])
    @grouping = @current_user.accepted_grouping_for(@assignment.id)
    m_logger = MarkusLogger.instance
    begin
      if @grouping.nil?
        raise I18n.t('create_group.fail.do_not_have_a_group')
      end
      # If grouping is not deletable for @current_user for whatever reason, fail.
      unless @grouping.deletable_by?(@current_user)
        raise I18n.t('groups.cant_delete')
      end
      # Note: This error shouldn't be raised normally, as the student shouldn't
      # be able to try to delete the group in this case.
      if @grouping.has_submission?
        raise I18n.t('groups.cant_delete_already_submitted')
      end

      if (@grouping.group.assignments.count == 1)
        # only update repo permissions if the group is not in another assignment
        @grouping.student_memberships.each do |member|
          @grouping.remove_member(member.id)
        end
      else
        # remove only the membership, but dont revoke permissions
        @grouping.student_memberships.includes(:user).each(&:destroy)
      end

      @grouping.destroy
      flash_message(:success, I18n.t('assignment.group.deleted'))
      m_logger.log("Student '#{current_user.user_name}' deleted group '" +
                   "#{@grouping.group.group_name}'.", MarkusLogger::INFO)

    rescue RuntimeError => e
      flash[:fail_notice] = e.message
      if @grouping.nil?
        m_logger.log(
           'Failed to delete group, since no accepted group for this user existed.' +
           "User: '#{current_user.user_name}', Error: '#{e.message}'.", MarkusLogger::ERROR)
      else
        m_logger.log("Failed to delete group '#{@grouping.group.group_name}'. User: '" +
                     "#{current_user.user_name}', Error: '#{e.message}'.", MarkusLogger::ERROR)
      end
    end
    redirect_to action: 'student_interface', id: params[:id]
  end

  def invite_member
    return unless request.post?
    @assignment = Assignment.find(params[:id])
    # if instructor formed group return
    return if @assignment.invalid_override

    @student = @current_user
    @grouping = @student.accepted_grouping_for(@assignment.id)
    if @grouping.nil?
      raise I18n.t('invite_student.fail.need_to_create_group')
    end

    to_invite = params[:invite_member].split(',')
    flash[:fail_notice] = []
    MarkusLogger.instance
    @grouping.invite(to_invite)
    flash[:fail_notice] = @grouping.errors['base']
    if flash[:fail_notice].blank?
      flash_message(:success, I18n.t('invite_student.success'))
    end
    redirect_to action: 'student_interface', id: @assignment.id
  end

  # Called by clicking the cancel link in the student's interface
  # i.e. cancels invitations
  def disinvite_member
    assignment = Assignment.find(params[:id])
    membership = StudentMembership.find(params[:membership])
    disinvited_student = membership.user
    membership.delete
    membership.save
    # update repository permissions
    grouping = current_user.accepted_grouping_for(assignment.id)
    grouping.update_repository_permissions
    m_logger = MarkusLogger.instance
    m_logger.log("Student '#{current_user.user_name}' cancelled invitation for " +
                 "'#{disinvited_student.user_name}'.")
    flash_message(:success, I18n.t('student.member_disinvited'))
    redirect_to action: :student_interface, id: assignment.id
  end

  # Deletes memberships which have been declined by students
  def delete_rejected
    @assignment = Assignment.find(params[:id])
    membership = StudentMembership.find(params[:membership])
    grouping = membership.grouping
    if current_user != grouping.inviter
      raise I18n.t('invite_student.fail.only_inviter')
    end
    membership.delete
    membership.save
    redirect_to action: 'student_interface', id: params[:id]
  end

  def update_collected_submissions
    @assignments = Assignment.all
  end

  # Refreshes the grade distribution graph
  def refresh_graph
    @assignment = Assignment.find(params[:id])
    @assignment.assignment_stat.refresh_grade_distribution
    respond_to do |format|
      format.js
    end
  end

  def view_summary
    @assignment = Assignment.find(params[:id])
    @current_ta = @assignment.tas.first
    @tas = @assignment.tas unless @assignment.nil?
  end

  def download_assignment_list
    assignments = Assignment.all

    case params[:file_format]
      when 'yml'
        map = {}
        map[:assignments] = []
        assignments.map do |assignment|
          m = {}
          DEFAULT_FIELDS.length.times do |i|
            m[DEFAULT_FIELDS[i]] = assignment.send(DEFAULT_FIELDS[i])
          end
          map[:assignments] << m
        end
        output = map.to_yaml
        format = 'text/yml'
      when 'csv'
        file_out = MarkusCSV.generate(assignments) do |assignment|
          DEFAULT_FIELDS.map do |f|
            assignment.send(f.to_s)
          end
        end
        send_data(file_out,
                  type: 'text/csv', disposition: 'attachment',
                  filename: 'assignment_list.csv')
        return
      else
        flash_message(:error, t(:incorrect_format))
        redirect_to action: 'index'
        return
    end

    send_data(output,
              filename: "assignments_#{Time.
                  now.strftime('%Y%m%dT%H%M%S')}.#{params[:file_format]}",
              type: format, disposition: 'inline')
  end

  def upload_assignment_list
    assignment_list = params[:assignment_list]

    if assignment_list.blank?
      flash_message(:error, I18n.t('csv.invalid_csv'))
      redirect_to action: 'index'
      return
    end

    encoding = params[:encoding]
    assignment_list = assignment_list.utf8_encode(encoding)

    case params[:file_format]
      when 'csv'
        result = MarkusCSV.parse(assignment_list) do |row|
          assignment = Assignment.find_or_create_by(short_identifier: row[0])
          attrs = Hash[DEFAULT_FIELDS.zip(row)]
          attrs.delete_if { |_, v| v.nil? }
          if assignment.new_record?
            assignment.submission_rule = NoLateSubmissionRule.new
            assignment.assignment_stat = AssignmentStat.new
            assignment.token_period = 1
            assignment.non_regenerating_tokens = false
            assignment.unlimited_tokens = false
          end
          assignment.update(attrs)
          raise CSVInvalidLineError unless assignment.valid?
        end
        unless result[:invalid_lines].empty?
          flash_message(:error, result[:invalid_lines])
        end
        unless result[:valid_lines].empty?
          flash_message(:success, result[:valid_lines])
        end
      when 'yml'
        begin
          map = YAML::load(assignment_list)
          map[:assignments].map do |row|
            row[:submission_rule] = NoLateSubmissionRule.new
            row[:assignment_stat] = AssignmentStat.new
            row[:token_period] = 1
            row[:non_regenerating_tokens] = false
            row[:unlimited_tokens] = false
            update_assignment!(row)
          end
        rescue ActiveRecord::ActiveRecordError, ArgumentError => e
          flash_message(:error, e.message)
          redirect_to action: 'index'
          return
        end
      else
        return
    end

    redirect_to action: 'index'
  end


  def populate_file_manager
    assignment = Assignment.find(params[:id])
    path = '/'
    revision = assignment.repo.get_latest_revision
    revision_identifier = revision.revision_identifier

    full_path = File.join(assignment.repository_folder, path)
    if revision.path_exists?(full_path)
      files = revision.files_at_path(full_path)
      files_info = get_files_info(files, assignment.id, revision_identifier, path)
      directories = revision.directories_at_path(full_path)
      directories_info = get_directories_info(directories, revision_identifier,
                                              path, assignment.id, 'populate_file_manager')
      render json: files_info + directories_info
    else
      render json: []
    end
  end

  def update_files
    @assignment = Assignment.find(params[:id])
    unless @assignment.can_upload_starter_code?
      raise t('student.submission.external_submit_only') #TODO: Update this
    end

    # We'll use this hash to carry over some error state to the
    # file_manager view.
    @file_manager_errors = Hash.new
    students_filename = []
    @path = params[:path] || '/'

    unless params[:new_files].nil?
      params[:new_files].each do |f|
        if f.size > MarkusConfigurator.markus_config_max_file_size
          @file_manager_errors[:size_conflict] =
              "Error occured while uploading file \"" +
                  f.original_filename +
                  '": The size of the uploaded file exceeds the maximum of ' +
                  "#{(MarkusConfigurator.markus_config_max_file_size/ 1000000.00)
                         .round(2)}" +
                  'MB.'
          render :file_manager
          return
        end
      end
    end

    @assignment.access_repo do |repo|
      assignment_folder = File.join(@assignment.repository_folder, @path)

      # Get the revision numbers for the files that we've seen - these
      # values will be the "expected revision numbers" that we'll provide
      # to the transaction to ensure that we don't overwrite a file that's
      # been revised since the user last saw it.
      file_revisions =
          params[:file_revisions].nil? ? {} : params[:file_revisions]
      file_revisions.merge!(file_revisions) do |_key, v1, _v2|
        v1.to_i rescue v1
      end

      # The files that will be deleted
      delete_files = params[:delete_files].nil? ? [] : params[:delete_files]

      # The files that will be added
      new_files = params[:new_files].nil? ? {} : params[:new_files]

      # Create transaction, setting the author.  Timestamp is implicit.
      txn = repo.get_transaction(current_user.user_name)

      log_messages = []
      begin
        if new_files.empty?
          # delete files marked for deletion
          delete_files.each do |filename|
            txn.remove(File.join(assignment_folder, filename),
                       file_revisions[filename])
            log_messages.push("Deleted file '#{filename}' for assignment" +
                              " '#{@assignment.short_identifier}' starter code.")
          end
        end

        # Add new files and replace existing files
        revision = repo.get_latest_revision
        files = revision.files_at_path(
            File.join('', @path))
        filenames = files.keys


        new_files.each do |file_object|
          filename = file_object.original_filename
          # sanitize_file_name in SubmissionsHelper
          if filename.nil?
            raise I18n.t('student.submission.invalid_file_name')
          end

          # Branch on whether the file is new or a replacement
          if filenames.include? filename
            file_object.rewind
            txn.replace(File.join(assignment_folder, filename), file_object.read,
                        file_object.content_type, revision.revision_identifier)
            log_messages.push("Replaced content of file '#{filename}'" +
                              ' for assignment' +
                              " '#{@assignment.short_identifier}' starter code.")
          else
            students_filename << filename
            # Sometimes the file pointer of file_object is at the end of the file.
            # In order to avoid empty uploaded files, rewind it to be save.
            file_object.rewind
            txn.add(File.join(assignment_folder,
                              sanitize_file_name(filename)),
                    file_object.read, file_object.content_type)
            log_messages.push("Submitted file '#{filename}'" +
                              " for assignment '#{@assignment.short_identifier}'" +
                              " starter code.")
          end
        end

        # finish transaction
        unless txn.has_jobs?
          flash[:transaction_warning] =
              I18n.t('student.submission.no_action_detected')
          # can't use redirect_to here. See comment of this action for details.
          set_filebrowser_vars(@grouping.group, @assignment)
          render :file_manager, id: assignment_id
          return
        end
        if repo.commit(txn)
          flash[:success] = I18n.t('update_files.success')
          # flush log messages
          m_logger = MarkusLogger.instance
          log_messages.each do |msg|
            m_logger.log(msg)
          end
        else
          @file_manager_errors[:update_conflicts] = txn.conflicts
        end

        # can't use redirect_to here. See comment of this action for details.
        set_filebrowser_vars(@assignment)
        redirect_to edit_assignment_path(@assignment)

      rescue Exception => e
        m_logger = MarkusLogger.instance
        m_logger.log(e.message)
        # can't use redirect_to here. See comment of this action for details.
        @file_manager_errors[:commit_error] = e.message
        set_filebrowser_vars(@assignment)
        redirect_to edit_assignment_path(@assignment)
      end
    end
  end

  def download
    @assignment = Assignment.find(params[:id])
    # find_appropriate_grouping can be found in SubmissionsHelper

    revision_identifier = params[:revision_identifier]
    path = params[:path] || '/'
    @assignment.access_repo do |repo|
      if revision_identifier.nil?
        @revision = repo.get_latest_revision
      else
        @revision = repo.get_revision(revision_identifier)
      end

      begin
        file = @revision.files_at_path(File.join(@assignment.repository_folder,
                                                 path))[params[:file_name]]
        file_contents = repo.download_as_string(file)
      rescue Exception => e
        render text: I18n.t('student.submission.missing_file',
                            file_name: params[:file_name], message: e.message)
        return
      end

      if SubmissionFile.is_binary?(file_contents)
        # If the file appears to be binary, send it as a download
        send_data file_contents,
                  disposition: 'attachment',
                  filename: params[:file_name]
      else
        # Otherwise, sanitize it for HTML and blast it out to the screen
        sanitized_contents = ERB::Util.html_escape(file_contents)
        render text: sanitized_contents, layout: 'sanitized_html'
      end
    end
  end




  private

    def sanitize_file_name(file_name)
      # If file_name is blank, return the empty string
      return '' if file_name.nil?
      File.basename(file_name).gsub(
          SubmissionFile::FILENAME_SANITIZATION_REGEXP,
          SubmissionFile::SUBSTITUTION_CHAR)
    end

    def set_filebrowser_vars(assignment)
      assignment.access_repo do |repo|
        @revision = repo.get_latest_revision
        @files = @revision.files_at_path(File.join(@assignment.repository_folder,
                                                   @path))
        @missing_assignment_files = []
        assignment.assignment_files.each do |assignment_file|
          unless @revision.path_exists?(File.join(assignment.repository_folder,
                                                  assignment_file.filename))
            @missing_assignment_files.push(assignment_file)
          end
        end
      end
    end


    def get_files_info(files, assignment_id, revision_identifier, path)
      files.map do |file_name, file|
        f = {}
        f[:id] = file.object_id
        f[:filename] = view_context.image_tag('icons/page_white_text.png') +
            view_context.link_to(" #{file_name}", action: 'download',
                                 id: assignment_id,
                                 revision_identifier: revision_identifier,
                                 file_name: file_name,
                                 path: path)
        f[:raw_name] = file_name
        f[:last_revised_date] = I18n.l(file.last_modified_date,
                                       format: :long_date)
        f[:last_modified_revision] = file.last_modified_revision
        f[:revision_by] = file.user_id
        f
      end
    end

    def get_directories_info(directories, revision_identifier, path, assignment_id, action)
      directories.map do |directory_name, directory|
        d = {}
        d[:id] = directory.object_id
        d[:filename] = view_context.image_tag('icons/folder.png') +
            # TODO: should the call below use
            # id: assignment_id and grouping_id: grouping_id
            # like the files info?
            view_context.link_to(" #{directory_name}/",
                                 action: action,
                                 id: assignment_id,
                                 revision_identifier: revision_identifier,
                                 path: File.join(path, directory_name))
        d[:last_revised_date] = I18n.l(directory.last_modified_date,
                                       format: :long_date)
        d[:last_modified_revision] = directory.last_modified_revision
        d[:revision_by] = directory.user_id
        d
      end
    end

    def update_assignment!(map)
      assignment = Assignment.
          find_or_create_by(short_identifier: map[:short_identifier])
      unless assignment.id
        assignment.submission_rule = NoLateSubmissionRule.new
        assignment.assignment_stat = AssignmentStat.new
        assignment.display_grader_names_to_students = false
      end
      assignment.update_attributes!(map)
      flash_message(:success, t('assignment.create_success'))
    end

  def process_assignment_form(assignment)
    assignment.update_attributes(assignment_params)

    # if there are no section due dates, destroy the objects that were created
    if params[:assignment][:section_due_dates_type].nil? ||
        params[:assignment][:section_due_dates_type] == '0'
      assignment.section_due_dates.each(&:destroy)
      assignment.section_due_dates_type = false
      assignment.section_groups_only = false
    else
      assignment.section_due_dates_type = true
      assignment.section_groups_only = true
    end

    # Due to some funkiness, we need to handle submission rules separately
    # from the main attribute update

    # First, figure out what kind of rule has been requested
    rule_attributes = params[:assignment][:submission_rule_attributes]
    rule_name       = rule_attributes[:type]

    [NoLateSubmissionRule, GracePeriodSubmissionRule,
     PenaltyPeriodSubmissionRule, PenaltyDecayPeriodSubmissionRule]
    if SubmissionRule.const_defined?(rule_name)
      potential_rule = SubmissionRule.const_get(rule_name)
    else
      raise SubmissionRule::InvalidRuleType, rule_name
    end

    # If the submission rule was changed, we need to do a more complicated
    # dance with the database in order to get things updated.
    if assignment.submission_rule.class != potential_rule

      # In this case, the easiest thing to do is nuke the old rule along
      # with all the periods and a new submission rule...this may cause
      # issues with foreign keys in the future, but not with the current
      # schema
      assignment.submission_rule.delete
      assignment.submission_rule = potential_rule.new

      # this part of the update is particularly hacky, because the incoming
      # data will include some mix of the old periods and new periods; in
      # the case of purely new periods the input is only an array, but in
      # the case of a mixture the input is a hash, and if there are no
      # periods at all then the periods_attributes will be nil
      periods = submission_rule_params[:periods_attributes]
      periods = case periods
                when Hash
                  # in this case, we do not care about the keys, because
                  # the new periods will have nonsense values for the key
                  # and the old periods are being discarded
                  periods.map { |_, p| p }.reject { |p| p.has_key?(:id) }
                when Array
                  periods
                else
                  []
                end
      # now that we know what periods we want to keep, we can create them
      periods.each do |p|
        assignment.submission_rule.periods << Period.new(p)
      end

    else # in this case Rails does what we want, so we'll take the easy route
      assignment.submission_rule.update_attributes(submission_rule_params)
    end

    if params[:is_group_assignment] == 'true'
      # Is the instructor forming groups?
      if assignment_params[:student_form_groups] == '0'
        assignment.invalid_override = true
        # Increase group_max so that create_all_groups button is not displayed
        # in the groups view.
        assignment.group_max = 2
      else
        assignment.student_form_groups = true
        assignment.invalid_override = false
        assignment.group_name_autogenerated = true
      end
    else
      assignment.student_form_groups = false
      assignment.invalid_override = false
      assignment.group_min = 1
      assignment.group_max = 1
    end

    assignment
  end

  def assignment_params
    params.require(:assignment).permit(
        :short_identifier,
        :description,
        :message,
        :repository_folder,
        :due_date,
        :allow_web_submits,
        :vcs_submit,
        :display_grader_names_to_students,
        :is_hidden,
        :group_min,
        :group_max,
        :student_form_groups,
        :group_name_autogenerated,
        :allow_remarks,
        :remark_due_date,
        :remark_message,
        :section_groups_only,
        :enable_test,
        :enable_student_tests,
        :has_peer_review,
        :assign_graders_to_criteria,
        :group_name_displayed,
        :invalid_override,
        :section_groups_only,
        :only_required_files,
        :scanned_exam,
        section_due_dates_attributes: [:_destroy,
                                       :id,
                                       :section_id,
                                       :due_date],
        assignment_files_attributes:  [:_destroy,
                                       :id,
                                       :filename]
    )
  end

  def submission_rule_params
    params.require(:assignment)
          .require(:submission_rule_attributes)
          .permit(:_destroy, :id, periods_attributes: [:id,
                                                       :deduction,
                                                       :interval,
                                                       :hours,
                                                       :_destroy])
  end
end
