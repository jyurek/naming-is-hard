class Sync < ActiveRecord::Base
  attr_accessible :action, :for_model, :consumer_token_id

  # store report hashes for each time the sync is run
  serialize :history, Array

  belongs_to :consumer_token

  default_scope order: :created_at

  delegate :user, :external_service, to: :consumer_token
  delegate :organization, to: :user

  validates_presence_of :consumer_token_id, :action, :for_model

  def external_service_name
    consumer_token.external_service_display_name
  end

  state_machine :state, initial: :dormant do
    event :mark_queued do
      transition :dormant => :queued
      # Similar to below, if sidekiq is killed when it restarts
      # it will take the previously running ones and re-queue them
      transition :running => :running
      transition :failed  => :queued
      transition :timeout => :queued
      transition :queued  => :queued
    end

    event :mark_running do
      transition :queued  => :running
      transition :failed  => :running
      transition :dormant => :running
      transition :timeout => :running
      # needed to handle case where a sidekiq worker was stopped during sync.run
      # see https://github.com/mperham/sidekiq/issues/243 for reference
      # we use sidekiq-middleware's unique_jobs to prevent rerunning sync
      # when it already being run by or is queued to sidekiq
      # see SyncRunner for unique_jobs set up
      transition :running => :running
    end

    event :complete do
      transition :running => :dormant
    end

    event :mark_failed do
      transition :queued  => :failed
      transition :running => :failed
      transition :dormant => :failed
      transition :failed  => :failed
      transition :timeout => :failed
    end

    event :mark_timeout do
      transition :queued  => :timeout
      transition :running => :timeout
      transition :dormant => :timeout
      transition :timeout => :timeout
      transition :failed  => :timeout
    end

    state :dormant
    state :queued
    state :running
    state :failed
    state :timeout

    after_transition on: :mark_timeout, do: :record_fail
    after_transition on: :mark_failed,  do: :record_fail
    after_transition on: :complete,     do: :record_success
  end

  def incomplete?
    queued? || running?
  end

  def run(run_options = {})

    begin
      # each skip should be object data and errors
      @report = default_report(for_model)

      mark_running!

      options = Hash.new

      if action == 'update'
        options[:on_or_after] = Time.zone.parse((organization.last_successful_sync_at - 1.hour).to_s) unless organization.last_successful_sync_at.blank?

        if run_options[:on_or_after]
          run_options[:on_or_after] = Time.zone.parse(run_options[:on_or_after]) if run_options[:on_or_after].is_a?(String)
          options[:on_or_after] = run_options[:on_or_after]
        end
      end

      options[:page] = run_options[:page] || 1

      run_options[:fetch_timeout] ||= 1.minute
      run_options[:timeout]       ||= 4.hours

      provider_supports_pagination = provider_supports_pagination_for_object(consumer_token, for_model_method)
      provider_objects_data = fetch_data(options, run_options)

      while provider_objects_data.try(:length) > 0
        # note doesn't handle if object was deleted externally
        provider_objects_data.each do |object_data|
          process_object_data(object_data)
        end

        options[:page] += 1

        # Harvest API only supports pagination on Invoices, not customers or payments
        break unless provider_supports_pagination

        raise Timeout::Error if Time.zone.now > @report[:started_at] + run_options[:timeout]

        provider_objects_data = fetch_data(options, run_options)
      end

      history << @report
      complete!

    rescue Timeout::Error => exception
      report_failure exception, true
      logger.error("Exception in Sync#run: Sync.id #{id}, #{exception.message}, #{exception.backtrace.first}")
      raise
    rescue Nokogiri::XML::XPath::SyntaxError, AuthorizationFailure, OAuth::Problem, Harvest::Unauthorized => exception
      report_failure exception
      logger.error("Exception in Sync#run: Sync.id #{id}, #{exception.message}, #{exception.backtrace.first}")
      SyncMailer.report_invalid_token(self).deliver
      consumer_token.destroy
      raise
    rescue Exception => exception
      report_failure exception
      logger.error("Exception in Sync#run: Sync.id #{id}, #{exception.message}, #{exception.backtrace.first}")
      raise
    ensure
      logger.info("Sync#run has ended. Sync.id: #{id}")
    end
    @report
  end

  def organization
    user.organization
  end

  def for_model_method
    for_model.tableize
  end

  def next_model
    models_in_order = consumer_token.to_sync_models_in_order
    current_index = models_in_order.index(for_model)
    next_index = current_index + 1

    # return nil if current model is last in order
    return nil if next_index == models_in_order.size
    models_in_order[next_index]
  end

  private
  def fetch_data(options, run_options, max_retries = false)
    Timeout::timeout(run_options[:fetch_timeout]) do
      remove_blank_attributes(consumer_token.send(for_model_method, options))
    end
  rescue Timeout::Error
    # If we keep hitting the timeout, raise so that we know why it blew up
    raise Timeout::Error if max_retries

    # Just try one more time for now.
    fetch_data(options, run_options, true)
  end

  def report_failure(exception, timeout=false)
    @report[:exception_msg] = exception.message

    timeout ? mark_timeout! : mark_failed!

    save_report

    Airbrake.notify exception

    # mark_timeout! and mark_failed! may throw an exception
  rescue => e
    Airbrake.notify e
  end

  def provider_supports_pagination_for_object(token, for_model_method)
    return true if token.is_a?(QuickbooksToken) || for_model_method == 'invoices'
    return false
  end

  def process_object_data(object_data)
    # Invoices need a customer association...
    if object_data[:external_customer_id]
      object_data[:customer_id] = organization.customers.find_by_external_service_id(object_data[:external_customer_id]).try(:id)
    end

    if object_data[:external_invoice_ids]
      external_invoice_ids =  object_data.delete(:external_invoice_ids)
      external_invoice_ids.each do |external_invoice_id|
        object_data[:invoice_id] = organization.invoices.find_by_external_service_id(external_invoice_id).try(:id)
        create_or_update_object_from(object_data)
      end
    else
      create_or_update_object_from(object_data)
    end
  end

  def create_or_update_object_from(object_data)
    imported_object = matching_record_with_attributes_from(object_data) ||
      build_associated_object_from(object_data)

    save_object(imported_object)
  end

  def save_object(object)
    if object.new_record? || object.changed?
      @report[:count] += 1 if object.save

      if object.errors.present?
        @report[:allowable_skips][:missing_customer_count] += 1 if object.errors.delete(:customer_id)
        @report[:allowable_skips][:missing_invoice_count]  += 1 if for_model == 'ExternalPayment' && object.errors.delete(:invoice_id)
      end

      # Re-check errors hash; if missing customer_id was the only thing, errors.present? will be false
      @report[:skips] << { errors: object.errors.messages } if object.errors.present?
    end
  end

  def build_associated_object_from(data)
    organization.send(for_model_method).build(data)
  end

  def matching_record_with_attributes_from(data)
    # ExternalPayments have an array of invoice IDs, so we break into multiple records
    # ExternalPayments(external_service_id) isn't a unique id any more :(
    if for_model_method == 'external_payments'
      matching_record = organization.external_payments.find_by_external_service_id_and_invoice_id(data[:external_service_id].to_i, data[:invoice_id].to_i)
    else
      matching_record = organization.send(for_model_method).find_by_external_service_id(data[:external_service_id].to_i)
    end
    matching_record.attributes = data if matching_record
    matching_record
  end

  def record_fail
    organization.last_sync_at = Time.zone.now

    organization.save(validate: false)
  rescue => e
    Airbrake.notify e
  end

  def record_success
    is_first_sync = (organization.last_successful_sync_at == nil)
    organization.last_sync_at            = Time.zone.now
    organization.last_successful_sync_at = organization.last_sync_at

    organization.save(validate: false)

    send_first_sync_email if is_first_sync
  rescue => e
    Airbrake.notify e
  end

  def send_first_sync_email
    SyncMailer.first_sync_complete(self).deliver
  end

  def default_report(model)
    self.send("#{model.underscore}_report")
  end

  def customer_report
    # Customer doesn't have any allowable skips (yet?)
    invoice_report.except(:allowable_skips)
  end

  def external_payment_report
    # Payments for QuickBooks don't have a customer if it's a Job payment
    hash = invoice_report
    hash[:allowable_skips].merge!({missing_invoice_count: 0})
    hash
  end

  def invoice_report
    { skips: Array.new, count: 0, allowable_skips: {missing_customer_count: 0}, started_at: Time.zone.now, exception_msg: nil }
  end

  def save_report
    history << @report

    # skipping save when new record
    # because we assume that the sync will be save separately
    # with rest of attributes
    save unless new_record?
  end

  def remove_blank_attributes(attributes_array)
    attributes_array.map do |attributes_hash|
      attributes_hash.delete_if { |k,v| v.blank? }
    end
  end
end
