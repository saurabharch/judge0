class SubmissionsController < ApplicationController
  before_action :authorize_request, only: [:index, :destroy]
  before_action :check_maintenance, only: [:create, :destroy]

  def index
    render_invalid_field_error and return if has_invalid_field

    page = params[:page].try(:to_i) || 1
    per_page = params[:per_page].try(:to_i) || Submission.per_page

    if page <= 0
      render json: { error: "invalid page: #{page}" }, status: :bad_request
      return
    elsif per_page < 0
      render json: { error: "invalid per_page: #{per_page}" }, status: :bad_request
      return
    end

    submissions = Submission.paginate(page: page, per_page: per_page)
    serializable_submissions = ActiveModelSerializers::SerializableResource.new(
      submissions, { each_serializer: SubmissionSerializer, base64_encoded: params[:base64_encoded] == "true", fields: requested_fields }
    )

    render json: {
      submissions: serializable_submissions.as_json,
      meta: pagination_dict(submissions)
    }
  rescue Encoding::UndefinedConversionError => e
    render json: {
      error: "some attributes for one or more submissions cannot be converted to UTF-8, use base64_encoded=true query parameter"
    }, status: :bad_request
  end

  def destroy
    if !Config::ENABLE_SUBMISSION_DELETE
      render json: { error: "delete not allowed" }, status: :bad_request
      return
    end

    render_invalid_field_error and return if has_invalid_field

    submission = Submission.find_by!(token: params[:token])

    if submission.status == Status.queue || submission.status == Status.process
      render json: {
        error: "submission cannot be deleted because its status is #{submission.status.id} (#{submission.status.name})"
      }, status: :bad_request
      return
    end

    submission.delete

    # Forcing base64_encoded=true because it guarantees user will get requested data after delete.
    render json: submission, base64_encoded: true, fields: requested_fields
  end

  def show
    render_invalid_field_error and return if has_invalid_field
    render json: Submission.find_by!(token: params[:token]), base64_encoded: params[:base64_encoded] == "true", fields: requested_fields
  rescue Encoding::UndefinedConversionError => e
    render json: {
      error: "some attributes for this submission cannot be converted to UTF-8, use base64_encoded=true query parameter"
    }, status: :bad_request
  end

  def create
    wait = params[:wait] == "true"
    if wait && !Config::ENABLE_WAIT_RESULT
      render json: { error: "wait not allowed" }, status: :bad_request
      return
    end

    if Resque.size("default") >= Config::MAX_QUEUE_SIZE
      render json: { error: "queue is full" }, status: :service_unavailable
      return
    end

    submission = Submission.new(submission_params)

    if submission.save
      if wait
        begin
          render_invalid_field_error and return if has_invalid_field
          IsolateJob.perform_now(submission)
          render json: submission, status: :created, base64_encoded: params[:base64_encoded] == "true", fields: requested_fields
        rescue Encoding::UndefinedConversionError => e
          render json: {
            token: submission.token,
            error: "some attributes for this submission cannot be converted to UTF-8, use base64_encoded=true query parameter"
          }, status: :created
        end
      else
        IsolateJob.perform_later(submission)
        render json: submission, status: :created, fields: [:token]
      end
    else
      render json: submission.errors, status: :unprocessable_entity
    end
  end

  private

  def submission_params
    submission_params = params.permit(
      :source_code,
      :language_id,
      :compiler_options,
      :command_line_arguments,
      :number_of_runs,
      :stdin,
      :expected_output,
      :cpu_time_limit,
      :cpu_extra_time,
      :wall_time_limit,
      :memory_limit,
      :stack_limit,
      :max_processes_and_or_threads,
      :enable_per_process_and_thread_time_limit,
      :enable_per_process_and_thread_memory_limit,
      :max_file_size,
      :redirect_stderr_to_stdout,
      :callback_url
    )

    params[:base64_encoded] == "true" ? decode_params(submission_params) : submission_params
  end

  def decode_params(params)
    params[:source_code] = Base64Service.decode(params[:source_code])
    params[:stdin] = Base64Service.decode(params[:stdin])
    params[:expected_output] = Base64Service.decode(params[:expected_output])
    params
  end

  def has_invalid_field
    @@universal_field ||= "*".to_sym

    return true if @invalid_field.present?
    return false if @requested_fields.present?

    fields = params[:fields].to_s.split(",").collect(&:to_sym)
    fields.each do |field|
      if field != @@universal_field && !SubmissionSerializer._attributes.include?(field)
        @invalid_field = field
        return true
      end
    end

    if fields.include?(@@universal_field)
      fields = SubmissionSerializer._attributes
    end

    @requested_fields = fields.presence || SubmissionSerializer.default_fields

    false
  end

  def requested_fields
    has_invalid_field
    @requested_fields
  end

  def render_invalid_field_error
    render json: { error: "invalid field #{@invalid_field}" }, status: :bad_request if has_invalid_field
  end
end
