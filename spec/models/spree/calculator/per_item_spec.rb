require 'spec_helper'

describe Spree::Calculator::PerItem do
  let(:calculator) { Spree::Calculator::PerItem.new(preferred_amount: 10) }
  let(:shipping_calculable) { double(:calculable) }
  let(:line_item) { build(:line_item, quantity: 5) }

  it "correctly calculates on a single line item object" do
    calculator.stub(calculable: shipping_calculable)
    calculator.compute(line_item).to_f.should == 50 # 5 x 10
  end

  context "extends LocalizedNumber" do
    it_behaves_like "a model using the LocalizedNumber module", [:preferred_amount]
  end
end
