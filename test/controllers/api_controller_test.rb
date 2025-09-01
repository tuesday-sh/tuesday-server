require "test_helper"

class ApiControllerTest < ActionDispatch::IntegrationTest
  test "should get message" do
    get api_up_url
    assert_response :success
  end
end
