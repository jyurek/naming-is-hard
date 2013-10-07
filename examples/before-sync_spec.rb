require 'spec_helper'

describe Sync do
  let(:user) { FactoryGirl.create(:user_with_quickbooks_account) }
  let(:organization) { user.organization }
  let!(:qb_token) { FactoryGirl.create(:quickbooks_with_real_token,
                                      user: user) }
  let(:sync) { FactoryGirl.create(:sync,
                                  for_model: 'Customer',
                                  consumer_token: qb_token) }

  describe 'default_report' do
    context 'Customer model' do
      it 'returns report ready to build on' do
        default = sync.send(:default_report, 'Customer')
        default[:exception_msg].should == nil
        default[:skips].should == Array.new
        default[:count].should == 0
        default[:allowable_skips].should be_nil
        default[:started_at].should be_a_kind_of ActiveSupport::TimeWithZone
      end
    end
    context 'Invoice model' do
      it 'returns report ready to build on' do
        default = sync.send(:default_report, 'Invoice')
        default[:exception_msg].should == nil
        default[:skips].should == Array.new
        default[:count].should == 0
        default[:allowable_skips].should == {missing_customer_count: 0}
        default[:started_at].should be_a_kind_of ActiveSupport::TimeWithZone
      end
    end
    context 'ExternalPayment model' do
      it 'returns report ready to build on' do
        default = sync.send(:default_report, 'ExternalPayment')
        default[:exception_msg].should == nil
        default[:skips].should == Array.new
        default[:count].should == 0
        default[:allowable_skips].should == {missing_customer_count: 0, missing_invoice_count: 0}
        default[:started_at].should be_a_kind_of ActiveSupport::TimeWithZone
      end
    end
  end

  describe "on_or_after" do
    context 'update syncs' do
      before do
        sync.action = 'update'
      end

      it "uses the passed in param to override" do
        organization.last_successful_sync_at = Time.zone.parse('2020-01-01')

        QuickbooksToken.any_instance.should_receive(:customers).with({page: 1, on_or_after: Time.zone.parse('2010-01-01')}).and_return([])

        sync.run(on_or_after: Time.zone.parse('2010-01-01'))
      end

      it "uses the organization last_successful_sync_at minus an hour to account for unsynchronized clocks" do
        organization.last_successful_sync_at = Time.zone.parse('2020-01-01')

        an_hour_earlier = Time.zone.parse('2020-01-01') - 1.hour

        QuickbooksToken.any_instance.should_receive(:customers).with({page: 1, on_or_after: an_hour_earlier}).and_return([])

        sync.run
      end

      it "ignores if no successful sync" do
        organization.last_successful_sync_at = nil

        QuickbooksToken.any_instance.should_receive(:customers).with({page: 1}).and_return([])

        sync.run
      end

      it "converts string params to date" do
        QuickbooksToken.any_instance.should_receive(:customers).with({page: 1, on_or_after: Time.zone.parse('2010-01-01 00:00:00 UTC')}).and_return([])

        sync.run(on_or_after: '2010-01-01')
      end
    end

    context 'create sync' do
      before do
        sync.action = 'create'
      end

      it "ignores organization last_successful_sync_at" do

        organization.last_successful_sync_at = Time.zone.parse('2020-01-01')

        QuickbooksToken.any_instance.should_receive(:customers).with({page: 1}).and_return([])

        sync.run
      end

      it "ignores :on_or_after" do
        QuickbooksToken.any_instance.should_receive(:customers).with({page: 1}).and_return([])

        sync.run(on_or_after: Time.zone.parse('2010-01-01'))
      end
    end

    context 'full sync' do
      before do
        sync.action = 'full'
      end

      it "ignores organization last_successful_sync_at" do
        organization.last_successful_sync_at = Time.zone.parse('2020-01-01')

        QuickbooksToken.any_instance.should_receive(:customers).with({page: 1}).and_return([])

        sync.run
      end

      it "ignores :on_or_after" do
        QuickbooksToken.any_instance.should_receive(:customers).with({page: 1}).and_return([])

        sync.run(on_or_after: Time.zone.parse('2010-01-01'))
      end
    end
  end

  describe "organization" do
    it "sends an email at the completion of a sync" do
      org = sync.organization

      org.last_successful_sync_at.should be_nil
      sync.stub(state: 'running')
      sync.complete!

      ActionMailer::Base.deliveries.should_not be_empty
    end

    it "returns organization associated with consumer token's user" do
      sync.organization.should == organization
    end

    shared_examples_for "last_sync_dates" do
      it "updates last_sync_at and last_successful_sync_at for successful sync" do
        org = sync.organization

        org.last_sync_at.should            be_nil
        org.last_successful_sync_at.should be_nil

        sync.stub(state: 'running')
        sync.complete!

        org.reload

        org.last_sync_at.should_not            be_nil
        org.last_successful_sync_at.should_not be_nil

        org.last_sync_at.should == organization.last_successful_sync_at
      end

      it "updates last_sync_at BUT NOT last_successful_sync_at for failed sync" do
        org = sync.organization

        org.last_sync_at.should            be_nil
        org.last_successful_sync_at.should be_nil

        sync.stub(state: 'running')
        sync.mark_failed!

        org.reload

        org.last_sync_at.should_not        be_nil
        org.last_successful_sync_at.should be_nil
      end
    end

    context "a valid organization" do
      it_should_behave_like "last_sync_dates"
    end

    context "an invalid organization" do
      before do
        organization.phone = nil
      end

      it_should_behave_like "last_sync_dates"
    end

    context "exception handling" do
      before do
        org = sync.organization
        org.stub(:save){ raise "D'oh!" }

        sync.state = 'running'
      end

      it "notifies airbrake on exception in complete!" do
        Airbrake.should_receive(:notify)

        sync.complete!
      end

      it "notifies airbrake on exception in mark_failed!" do
        Airbrake.should_receive(:notify)

        sync.mark_failed!
      end

      it "sets state to dormant" do
        sync.complete!

        sync.state.should == 'dormant'
      end

      it "sets state to failed" do
        sync.mark_failed!

        sync.state.should == 'failed'
      end
    end

  end

  describe "for_model_method" do
    it "returns tableized version of for_model" do
      sync.for_model_method == sync.for_model.tableize
    end
  end

  describe "pagination" do
    it "sets start page" do
      QuickbooksToken.any_instance.should_receive(:customers).with({page: 1}).and_return([])
      sync.run
    end
  end

  describe "timeout" do
    it "transitions to timeout after two timeouts" do
      QuickbooksToken.any_instance.should_receive(:customers).with({page: 1}).twice.and_raise(Timeout::Error)

      expect { sync.run }.to raise_error(Timeout::Error)
      sync.state.should == 'timeout'
    end

    it "raises if whole thing has been running longer than 4 hours (default)", vcr: true do
      timeout = Time.zone.now - (4*60+1).minutes
      sync.should_receive(:default_report).and_return({ skips: Array.new, count: 0, started_at: timeout, exception_msg: nil })

      expect { sync.run }.to raise_error(Timeout::Error)
      sync.state.should == 'timeout'
    end

    it "raises if whole thing has been running longer than 5 minutes (set in options hash)", vcr: true do
      six_minutes_ago = Time.zone.now - 6.minutes
      sync.should_receive(:default_report).and_return({ skips: Array.new, count: 0, started_at: six_minutes_ago, exception_msg: nil })

      expect { sync.run(timeout: 5.minutes) }.to raise_error(Timeout::Error)
      sync.state.should == 'timeout'
    end
  end

  describe "process_object_data" do
    let(:customer){ FactoryGirl.create(:customer, organization: organization) }
    let(:data){ { organization: organization, external_service_id: 1, customer_id: customer.id, date: Time.zone.now, due: Time.zone.now  } }
    before do
      sync.for_model = 'Invoice'
      sync.instance_variable_set(:@report, {count: 0})
    end

    it "adds a new one if there isn't one that exists" do
      expect{ sync.send(:process_object_data, data) }.to change{Invoice.count}.from(0).to(1)
    end

    it "updates existing" do
      i = FactoryGirl.create(:invoice, data)

      data[:due] = Time.zone.parse('2020-01-01')
      expect{ sync.send(:process_object_data, data) }.to_not change{Invoice.count}.from(1).to(2)

      i.reload
      i.due.should == Date.parse('2020-01-01')
    end
  end

  describe "build_associated_object_from" do
    it "populates an associated instance of for_model to organization" do
      data = { name: 'Davis' }
      new_object = sync.send(:build_associated_object_from, data)
      new_object.organization.should == organization
      new_object.should be_kind_of(Customer)
      new_object.name.should == data[:name]
    end
  end

  describe "matching_record_with_attributes_from" do
    let(:data) { { organization: organization, external_service_id: 1 } }

    it "returns nil whent there is no matching record" do
      sync.send(:matching_record_with_attributes_from, data).should be_nil
    end

    context 'when there is a matching record' do
      before do
        @customer = FactoryGirl.create(:customer, data)
        @invoice  = FactoryGirl.create(:invoice,  data)
      end

      it "returns organization's existing instance for external_service_id" do
        sync.send(:matching_record_with_attributes_from, data).should == @customer
      end

      it 'sets attributes of matching object to new values' do
        data[:name] = 'x'
        sync.send(:matching_record_with_attributes_from, data).name.should == data[:name]
      end

      it "returns organization's existing instance for external_service_id" do
        sync.for_model = 'Invoice'
        sync.send(:matching_record_with_attributes_from, data).should == @invoice
      end

      it 'sets attributes of matching object to new values' do
        sync.for_model = 'Invoice'
        data[:total] = 99.00

        sync.send(:matching_record_with_attributes_from, data).total.should == data[:total]
      end
    end
  end

  describe "next_model" do
    let(:sequence) { qb_token.to_sync_models_in_order}

    it "returns model that follows for_model in sequence" do
      sync.for_model = sequence.first
      sync.next_model.should == sequence[1]
    end

    it "returns nil if for_model is last in sequence" do
      sync.for_model = sequence.last
      sync.next_model.should be_nil
    end
  end

  describe "bad data" do
    it "handles bad data" do
      org1 = organization
      org2 = FactoryGirl.create(:organization)
      cust = FactoryGirl.create(:customer, organization: org1, external_service_id: 12 )

      org1.reload
      org1.invoices.count.should == 0

      QuickbooksToken.any_instance.should_receive(:invoices).with(page: 1).and_return{
        [{ customer_id: cust.id,
                  external_customer_id: 12,
                  external_service_id: 1465,
                  external_updated_at: Time.zone.parse("2013-03-13 18:59:37 +0000"),
                  external_balance: 13735.83,
                  number: "1085",
                  date: Date.parse("Mon, 31 Dec 2012"),
                  due: Date.parse("Tue, 01 Jan 2013"),
                  total: 15500.0,
                  notes: nil,
                  organization_id: org2.id}]
        }

      QuickbooksToken.any_instance.should_receive(:invoices).with(page: 2).and_return{ [] }

      sync.stub(:for_model){ 'Invoice' }
      sync.run

      org1.reload
      org1.invoices.count.should == 1

      org2.reload
      org2.invoices.should == []
    end

  end

  describe "run", :vcr do
    describe 'exception handling' do
      context 'allowable skips' do
        describe 'missing customer_id on invoice' do
          before do
            invoice_attributes = { external_customer_id: nil,
              external_service_id: 1,
              external_updated_at: Time.zone.now,
              external_balance: 99.99,
              number: "42",
              date: Date.parse("2010-01-01"),
              due: Date.parse("2010-02-01"),
              total: 99.99,
              notes: nil
            }

            QuickbooksToken.any_instance.should_receive(:invoices).with(page: 1).and_return{ [invoice_attributes] }
            QuickbooksToken.any_instance.should_receive(:invoices).with(page: 2).and_return{ [] }

            sync.update_column(:for_model, 'Invoice')
          end

          it 'reports no skips' do
            report = sync.run
            report[:skips].should == Array.new
          end

          it 'does not import anything' do
            report = sync.run
            report[:count].should == 0
          end

          it 'is successful' do
            sync.run
            sync.state.should == "dormant"
          end

          it 'reports a single invoice with no customer' do
            report = sync.run
            report[:allowable_skips][:missing_customer_count].should == 1
          end
        end

        describe 'missing customer_id on invoice payment' do
          before do
            invoice = FactoryGirl.create(:invoice, organization: organization, external_service_id: 99 )
            invoice_payment_attributes = { external_customer_id: nil,
              external_service_id: 1,
              external_updated_at: Time.zone.now,
              external_invoice_ids: [invoice.external_service_id],
              amount: 99.99,
              date: Date.parse("2010-01-01")
            }

            QuickbooksToken.any_instance.should_receive(:external_payments).with(page: 1).and_return{ [invoice_payment_attributes] }
            QuickbooksToken.any_instance.should_receive(:external_payments).with(page: 2).and_return{ [] }

            sync.update_column(:for_model, 'ExternalPayment')
          end

          it 'reports no skips' do
            report = sync.run
            report[:skips].should == Array.new
          end

          it 'does not import anything' do
            report = sync.run
            report[:count].should == 0
          end

          it 'is successful' do
            sync.run
            sync.state.should == "dormant"
          end

          it 'reports a single invoice with no customer' do
            report = sync.run
            report[:allowable_skips][:missing_customer_count].should == 1
          end
        end

        describe 'cannot find invoice from invoice payment' do
          before do
            customer = FactoryGirl.create(:customer, organization: organization, external_service_id: 99 )
            invoice_payment_attributes = { external_customer_id: 99,
              external_service_id: 1,
              external_updated_at: Time.zone.now,
              external_invoice_ids: [999999],
              amount: 99.99,
              date: Date.parse("2010-01-01")
            }

            QuickbooksToken.any_instance.should_receive(:external_payments).with(page: 1).and_return{ [invoice_payment_attributes] }
            QuickbooksToken.any_instance.should_receive(:external_payments).with(page: 2).and_return{ [] }

            sync.update_column(:for_model, 'ExternalPayment')
          end

          it 'reports no skips' do
            report = sync.run
            report[:skips].should == Array.new
          end

          it 'does not import anything' do
            report = sync.run
            report[:count].should == 0
          end

          it 'is successful' do
            sync.run
            sync.state.should == "dormant"
          end

          it 'reports a single invoice with no invoice' do
            report = sync.run
            report[:allowable_skips][:missing_invoice_count].should == 1
          end
        end
      end

      context 'error handling' do
        before do
          qb_token.stub(:customers) { raise Exception }
        end

        it 'handles all exceptions via SyncErrorHandler then re-raises the exception' do
          handler = double("SyncErrorHandler")
          handler.should_receive(:update_report)
          handler.should_receive(:handle)
          SyncErrorHandler.stub(:new).and_return(handler)

          expect { sync.run }.to raise_error(Exception)
        end
      end

      # These tests may still be useful as integration tests between
      # Sync and SyncErrorHandler...

      # context 'exceptions' do
      #   before do
      #     qb_token.stub(:customers) { raise StandardError }
      #   end

      #   it 'add exception to report' do
      #     expect { sync.run }.to raise_error(StandardError)
      #     sync.history.last[:exception_msg].should == 'StandardError'
      #   end

      #   it 'change state to failed' do
      #     expect { sync.run }.to raise_error(standarderror)
      #     sync.state.should == 'failed'
      #   end

      #   it 'calls mark_failed' do
      #     sync.should_receive(:mark_failed)
      #     expect{ sync.run }.to raise_error(standarderror)
      #   end

      #   it 'notifies airbrake' do
      #     airbrake.should_receive(:notify)
      #     expect{ sync.run }.to raise_error(standarderror)
      #   end
      # end

      # context 'expired quickbooks online account' do
      #   # If the User is using QuickBooks Online and stops paying, we get
      #   # terrible unhandled errors from the API/Quickeebooks.
      #   it 'handles terrible message returned by Intuit API' do
      #     user.quickbooks_token.should_not be_nil

      #     qb_token.stub(:customers) { raise Nokogiri::XML::XPath::SyntaxError }
      #     expect { sync.run }.to raise_error(Nokogiri::XML::XPath::SyntaxError )
      #     ActionMailer::Base.deliveries.should_not be_empty

      #     user.reload
      #     user.quickbooks_token.should be_nil
      #   end
      # end

      # context 'if oauth invalid token raised' do
      #   it 'handles AuthorizationFailure' do
      #     user.quickbooks_token.should_not be_nil

      #     qb_token.stub(:customers) { raise AuthorizationFailure }
      #     expect { sync.run }.to raise_error(AuthorizationFailure)
      #     ActionMailer::Base.deliveries.should_not be_empty

      #     user.reload
      #     user.quickbooks_token.should be_nil
      #   end

      #   it 'handles OAuth::Problem => token_rejected' do
      #     user.quickbooks_token.should_not be_nil

      #     qb_token.stub(:customers) { raise OAuth::Problem.new('token_rejected') }
      #     expect { sync.run }.to raise_error(OAuth::Problem)
      #     ActionMailer::Base.deliveries.should_not be_empty

      #     user.reload
      #     user.quickbooks_token.should be_nil
      #   end
      #end
    end

    describe "create" do
      it "creates customer instances from consumer_token provider data" do
        expect { sync.run }.to change { organization.customers.count }.from(0).to(3)
      end

      it "creates invoice instances from consumer_token provider data" do
        # we have to get the customers before the invoices
        sync.run
        sync.for_model = 'Invoice'
        expect { sync.run }.to change { organization.invoices.count }.from(0).to(2)
      end

      it "creates payment instances from consumer_token provider data" do
        sync.run

        sync.for_model = 'Invoice'
        sync.run

        sync.for_model = 'ExternalPayment'
        expect { sync.run }.to change { organization.external_payments.count }.from(0).to(1)
      end

      # only handling successful case now
      # because we lack stable quickbooks test data with bad data
      it "returns a report of the sync" do
        report = sync.run
        report[:skips].should == Array.new
        report[:count].should == 3
        report[:started_at].should be_kind_of Time
      end

      it "sets each record's external_updated_at" do
        sync.run
        customer = organization.customers.sort_by{|c| c.name}.first

        qb_record = QuickbooksService.new(qb_token).entries('Customer').first
        last_quickbooks_update_time = qb_record.meta_data.last_updated_time
        customer.external_updated_at.should == last_quickbooks_update_time
      end

      it "changes the sync's state" do
        sync.mark_queued
        expect { sync.run }.to change { sync.state }.from('queued').to('dormant')
      end

      it "doesn't create duplicate records" do
        expect { sync.run }.to     change { organization.customers.count }.from(0).to(3)
        expect { sync.run }.to_not change { organization.customers.count }.from(3).to(6)
      end

      context "ExternalPayments" do
        def create_payments
          c1 = FactoryGirl.create(:customer, organization: organization, external_service_id: 100 )
          i1 = FactoryGirl.create(:invoice,  organization: organization, external_service_id: 99, customer: c1 )
          i2 = FactoryGirl.create(:invoice,  organization: organization, external_service_id: 100 )

          [{ external_customer_id: c1.external_service_id,
                    external_service_id: 1,
                    external_updated_at: Time.zone.now,
                    external_invoice_ids: [i1.external_service_id, i2.external_service_id],
                    amount: 99.99,
                    date: Date.parse("2010-01-01")
                  },{ external_customer_id: c1.external_service_id,
                    external_service_id: 2,
                    external_updated_at: Time.zone.now,
                    external_invoice_ids: [i1.external_service_id],
                    amount: 88.88,
                    date: Date.parse("2010-01-02")
                  }]
        end

        it "Creates ExternalPayments" do
          payments = create_payments

          QuickbooksToken.any_instance.should_receive(:external_payments).with(page: 1).and_return{ payments }
          QuickbooksToken.any_instance.should_receive(:external_payments).with(page: 2).and_return{ [] }

          sync.for_model = 'ExternalPayment'

          expect{ sync.run }.to change{ExternalPayment.count}.from(0).to(3)
        end

        it "doesn't create duplicate records" do
          payments = create_payments

          QuickbooksToken.any_instance.should_receive(:external_payments).with(page: 1).twice.and_return{ payments }
          QuickbooksToken.any_instance.should_receive(:external_payments).with(page: 2).twice.and_return{ [] }

          sync.for_model = 'ExternalPayment'

          expect { sync.run }.to     change { organization.external_payments.count }.from(0).to(3)
          expect { sync.run }.to_not change { organization.external_payments.count }.from(3).to(6)
        end
      end
    end

    describe "update" do
      before do
        sync.run
      end

      it "updates instances of given model from consumer_token provider data" do
        sync.action = 'update'

        # NOTE: this is hard coded in 2nd request for sync.run in
        # spec/cassettes/Sync/run/update/\
        # updates_instances_of_given_model_from_consumer_token_provider_data.yml
        # if you change that file, you'll need to reinstate the following for
        # 1st customer of request that returns 'updated' values (at or about line 255):
        # <LastUpdatedTime>2012-08-14T21:00:45-07:00</LastUpdatedTime>
        # <Name>Davis McAlary</Name>
        updated_time = Time.zone.parse('2012-08-14T21:00:45-07:00')
        sync.run
        organization.customers.count.should == 3
        customer_from_quickbooks = organization.customers.sort_by{|c| c.name}.first
        customer_from_quickbooks.external_updated_at.should == updated_time
        customer_from_quickbooks.name.should == 'Davis McAlary'
      end
    end

    describe "mark_queued!" do
      context "when the sync task was previously running" do
        before do
          sync.update_attribute(:state, :running)
        end

        it "is still running" do
          sync.mark_queued!
          sync.should be_running
        end
      end
    end
  end
end
