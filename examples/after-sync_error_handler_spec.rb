require 'spec_helper'

describe SyncErrorHandler do

  let(:sync) { FactoryGirl.build(:sync) }

  let(:exception) { RuntimeError.new "Boom" }

  context "#invalid_token?" do
    it "returns true for exceptions that signify an invalid token" do
      invalid_token_exceptions.each do |ex|
        handler = handler_for(ex)
        handler.invalid_token?.should be_true
      end
    end

    it "returns false for other exceptions" do
      handler = handler_for(exception)
      handler.invalid_token?.should be_false
    end
  end

  context '#update_report' do
    it 'sets the exception_msg' do
      handler = handler_for(exception)

      handler.update_report(report = {})

      expect(report[:exception_msg]).to eq exception.message
    end
  end

  context '#handle' do
    it 'marks the sync as failed' do
      handler = handler_for(exception)

      handler.handle

      expect(sync).to be_failed
    end

    it 'notifies airbrake' do
      Airbrake.should_receive(:notify).with(exception)

      handler = handler_for(exception)

      handler.handle
    end

    context "when the error is a timeout" do
      it 'marks the sync as timed out' do
        handler = handler_for(Timeout::Error.new)

        handler.handle

        expect(sync).to be_timed_out
      end
    end

    context "when the error signifies an invalid token" do
      subject { handler_for(invalid_token_exceptions.first) }

      it 'sends an invalid token email' do
        mailer = double("Mailer")
        mailer.should_receive(:deliver)
        SyncMailer.should_receive(:report_invalid_token).with(sync).and_return(mailer)

        subject.handle
      end

      it 'destroys the token' do
        token_id = sync.consumer_token.id

        subject.handle

        expect(ConsumerToken.exists?(token_id)).to be_false
      end
    end
  end

  def handler_for(exception)
    # need to actually raise and rescue, so the exception will have a
    # proper backtrace
    raise exception
  rescue Exception
    SyncErrorHandler.new(sync) # $!
  end

  def invalid_token_exceptions
    [
      Nokogiri::XML::XPath::SyntaxError.new,
      AuthorizationFailure.new,
      OAuth::Problem.new("Some OAuth problem"),
      Harvest::Unauthorized.new
    ]
  end

end
