class SyncErrorHandler
  # These exception classes are assumed to indicate an invalid token and
  # should trigger that token being destroyed.
  INVALID_TOKEN_EXCEPTIONS = [
    Nokogiri::XML::XPath::SyntaxError,
    AuthorizationFailure,
    OAuth::Problem,
    Harvest::Unauthorized,
  ]

  def initialize(sync, exception = $!)
    Rails.logger.error("Exception in Sync#run: Sync.id #{sync.id}, #{exception.message}, #{exception.backtrace.first}")

    @sync = sync
    @exception = exception
  end

  def invalid_token?
    INVALID_TOKEN_EXCEPTIONS.include?(exception.class)
  end

  def update_report(report)
    report[:exception_msg] = exception.message
  end

  def handle
    update_sync_state
    handle_invalid_token if invalid_token?

    Airbrake.notify(exception)
  rescue => ex
    Airbrake.notify(ex)
  end

  private

  attr_reader :sync, :exception

  def update_sync_state
    if exception.is_a?(Timeout::Error)
      sync.mark_timeout!
    else
      sync.mark_failed!
    end
  end

  def handle_invalid_token
    SyncMailer.report_invalid_token(sync).deliver
    sync.consumer_token.destroy
  end

end
