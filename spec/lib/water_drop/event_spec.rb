require 'spec_helper'

RSpec.describe WaterDrop::Event do
  let(:topic) { double }
  let(:message) { [] }
  let(:producer) { double }

  subject { described_class.new(topic, message) }

  describe '#send!' do
    let(:message_producer) { double }
    let(:messages) { double }

    before do
      allow(WaterDrop)
        .to receive_message_chain(:config, :send_events?)
        .and_return(true)

      expect(WaterDrop::Pool).to receive(:with).and_yield(producer)
      expect(producer).to receive(:send_messages)
        .with(any_args)
    end

    it 'sends message with topic and message' do
      subject.send!
    end
  end
end
