module AssignmentHelper
  def course_options(instructor)
    if session[:user].role.name == 'Teaching Assistant'
      courses = []
      ta = Ta.find(session[:user].id)
      ta.ta_mappings.each {|mapping| courses << Course.find(mapping.course_id) }
      # If a TA created some courses before, s/he can still add new assignments to these courses.
      courses << Course.where(instructor_id: instructor.id)
      courses.flatten!
    # Administrator and Super-Administrator can see all courses
    elsif session[:user].role.name == 'Administrator' or session[:user].role.name == 'Super-Administrator'
      courses = Course.all
    elsif session[:user].role.name == 'Instructor'
      courses = Course.where(instructor_id: instructor.id)
      # instructor can see courses his/her TAs created
      ta_ids = []
      ta_ids << Instructor.get_my_tas(session[:user].id)
      ta_ids.flatten!
      ta_ids.each do |ta_id|
        ta = Ta.find(ta_id)
        ta.ta_mappings.each {|mapping| courses << Course.find(mapping.course_id) }
      end
    end
    options = []
    options << ['-----------', nil]
    courses.each do |course|
      options << [course.name, course.id]
    end
    options.uniq.sort
  end

  # round=0 added by E1450
  def questionnaire_options(assignment, type, _round = 0)
    questionnaires = Questionnaire.where(['private = 0 or instructor_id = ?', assignment.instructor_id]).order('name')
    options = []
    questionnaires.select {|x| x.type == type }.each do |questionnaire|
      options << [questionnaire.name, questionnaire.id]
    end
    options
  end

  def review_strategy_options
    review_strategy_options = []
    Assignment::REVIEW_STRATEGIES.each do |strategy|
      review_strategy_options << [strategy.to_s, strategy.to_s]
    end
    review_strategy_options
  end

  # retrive or create a due_date
  # use in views/assignment/edit.html.erb
  # Be careful it is a tricky method, for types other than "submission" and "review",
  # the parameter "round" should always be 0; for "submission" and "review" if you want
  # to get the due date for round n, the parameter "round" should be n-1.
  def due_date(assignment, type, round = 0)
    due_dates = assignment.find_due_dates(type)

    due_dates.delete_if {|due_date| due_date.due_at.nil? }
    due_dates.sort! {|x, y| x.due_at <=> y.due_at }

    if due_dates[round].nil? or round < 0
      due_date = AssignmentDueDate.new
      due_date.deadline_type_id = DeadlineType.find_by(name: type).id
      # creating new round
      # TODO: add code to assign default permission to the newly created due_date according to the due_date type
      due_date.submission_allowed_id = AssignmentDueDate.default_permission(type, 'submission_allowed')
      due_date.review_allowed_id = AssignmentDueDate.default_permission(type, 'can_review')
      due_date.review_of_review_allowed_id = AssignmentDueDate.default_permission(type, 'review_of_review_allowed')
      due_date
    else
      due_dates[round]
    end
  end

  def questionnaire(assignment, type, round_number)
    # E1450 changes
    if round_number.nil?
      questionnaire = assignment.questionnaires.find_by(type: type)
    else
      ass_ques = assignment.assignment_questionnaires.find_by(used_in_round: round_number)
      # make sure the assignment_questionnaire record is not empty
      unless ass_ques.nil?
        temp_num = ass_ques.questionnaire_id
        questionnaire = assignment.questionnaires.find_by(id: temp_num)
      end
    end
    # E1450 end
    questionnaire = Object.const_get(type).new if questionnaire.nil?

    questionnaire
  end

  # number added by E1450
  def assignment_questionnaire(assignment, type, number)
    questionnaire = assignment.questionnaires.find_by(type: type)

    if questionnaire.nil?
      default_weight = {}
      default_weight['ReviewQuestionnaire'] = 100
      default_weight['MetareviewQuestionnaire'] = 0
      default_weight['AuthorFeedbackQuestionnaire'] = 0
      default_weight['TeammateReviewQuestionnaire'] = 0
      default_weight['BookmarkRatingQuestionnaire'] = 0

      default_aq = AssignmentQuestionnaire.where(user_id: assignment.instructor_id, assignment_id: nil, questionnaire_id: nil).first
      default_limit = if default_aq.nil?
                        15
                      else
                        default_aq.notification_limit
                      end

      aq = AssignmentQuestionnaire.new
      aq.questionnaire_weight = default_weight[type]
      aq.notification_limit = default_limit
      aq.assignment = @assignment
      aq
    else
      # E1450 changes
      if number.nil?
        assignment.assignment_questionnaires.find_by(questionnaire_id: questionnaire.id)
      else
        assignment_by_usedinround = assignment.assignment_questionnaires.find_by(used_in_round: number)
        # make sure the assignment found by used in round is not empty
        if assignment_by_usedinround.nil?
          assignment.assignment_questionnaires.find_by(questionnaire_id: questionnaire.id)
        else
          assignment_by_usedinround
        end
      end
      # E1450 end
    end
  end

  def get_data_for_list_submissions(team)
    teams_users = TeamsUser.where(team_id: team.id)
    topic = SignedUpTeam.where(team_id: team.id).first.try :topic
    topic_identifier = topic.try :topic_identifier
    topic_name = topic.try :topic_name
    users_for_curr_team = []
    participants = []
    teams_users.each do |teams_user|
      user = User.find(teams_user.user_id)
      users_for_curr_team << user
      participants << Participant.where(["parent_id = ? AND user_id = ?", @assignment.id, user.id]).first
    end
    [topic_identifier ||= "", topic_name ||= "", users_for_curr_team, participants]
  end

  def get_team_name_color_in_list_submission(team)
    if team.try(:grade_for_submission) && team.try(:comment_for_submission)
      '#cd6133' # brown. submission grade has been assigned.
    else
      '#0984e3' # submission grade is not assigned yet.
    end
  end

  #Method extracted from scores method in assignment.rb This method computes and returns grades by rounds and
  #total_num_of_assessments and total_score when the assignment has varying rubrics by round
  def compute_grades_by_rounds(questions, team)
    grades_by_rounds = {}
    total_score = 0
    total_num_of_assessments = 0 # calculate grades for each rounds
    (1..self.num_review_rounds).each do |i|
      assessments = ReviewResponseMap.get_responses_for_team_round(team, i)
      round_sym = ("review" + i.to_s).to_sym
      grades_by_rounds[round_sym] = Answer.compute_scores(assessments, questions[round_sym])
      total_num_of_assessments += assessments.size
      total_score += grades_by_rounds[round_sym][:avg] * assessments.size.to_f unless grades_by_rounds[round_sym][:avg].nil?
    end
    return grades_by_rounds, total_num_of_assessments, total_score
  end

  # merge the grades from multiple rounds Jasmine:extracted from scores method in assignment.rb (for OSS Project E2009)
  def merge_grades_by_rounds(grades_by_rounds, num_of_assessments, total_score)
    team_scores = {:max => 0, :min => 0, :avg => nil}
    return team_scores if !num_of_assessments

    team_scores[:max] = -999_999_999
    team_scores[:min] = 999_999_999
    team_scores[:avg] = total_score/num_of_assessments
    (1..self.num_review_rounds).each do |i|
      round_sym = ("review" + i.to_s).to_sym
      if !grades_by_rounds[round_sym][:max].nil? && team_scores[:max] < grades_by_rounds[round_sym][:max]
        team_scores[:max] = grades_by_rounds[round_sym][:max]
      end
      if !grades_by_rounds[round_sym][:min].nil? && team_scores[:min] > grades_by_rounds[round_sym][:min]
        team_scores[:min] = grades_by_rounds[round_sym][:min]
      end
    end
    team_scores
  end

  #returns true if assignment has staggered deadline and topic_id is nil
  def staggered_and_no_topic?(topic_id)
    self.staggered_deadline? and topic_id.nil?
  end

  #returns true if reviews required is greater than reviews allowed
  def num_reviews_greater?(reviews_required, reviews_allowed)
    reviews_allowed && reviews_allowed != -1 && reviews_required > reviews_allowed
  end

  # for program 1 like assignment, if same rubric is used in both rounds,
  # the 'used_in_round' field in 'assignment_questionnaires' will be null,
  # since one field can only store one integer
  # if rev_q_ids is empty, Expertiza will try to find questionnaire whose type is 'ReviewQuestionnaire'.
  def get_questionnaire_ids(round)
    rev_q_ids = if round.nil?
                  AssignmentQuestionnaire.where(assignment_id: self.id)
                else
                  AssignmentQuestionnaire.where(assignment_id: self.id, used_in_round: round)
                end
    if rev_q_ids.empty?
      AssignmentQuestionnaire.where(assignment_id: self.id).find_each do |aq|
        rev_q_ids << aq if aq.questionnaire.type == "ReviewQuestionnaire"
      end
    end
    rev_q_ids
  end

  def review_type (responsemap_type,force)
    maps = responsemap_type.where(reviewed_object_id: self.id)
    maps.each {|map| map.delete(force) }
  end



end
