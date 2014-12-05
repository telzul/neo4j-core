require 'spec_helper'

# This expects that the database is using the test suite's password, 'neo4jrb rules,ok?'
# That password is set at the beginning of the specs if ENV['TEST_AUTHENTICATION'] is true.
describe 'Neo4j::Server::CypherAuthentication', api: :server, type: :authentication do
  require 'rake'

  def reload_tasks
    Rake::Task.clear
    load 'neo4j/tasks/neo4j_server.rake'
  end

  def auth_setup
    reload_tasks
    tasks = ['neo4j:stop', 'neo4j:enable_auth', 'neo4j:start']
    tasks.each do |task|
      Rake::Task[task].invoke
      sleep 1
    end
  end

  def auth_breakdown
    reload_tasks
    tasks = ['neo4j:stop', 'neo4j:disable_auth', 'neo4j:start']
    tasks.each do |task|
      Rake::Task[task].invoke
      sleep 1
    end
  end

  before(:all) do
    auth_setup
    @default_password = 'neo4j'
    @suite_default = 'neo4jrb rules, ok?'
    @uri = URI.parse("http://localhost:7474/user/neo4j/password")
    Net::HTTP.post_form(@uri, { 'password' => @default_password, 'new_password' => @suite_default })
  end

  after(:all) do
    auth_breakdown
    Net::HTTP.post_form(@uri, { 'password' => @suite_default, 'new_password' => @default_password })
  end

  before { Neo4j::Session.current.close if Neo4j::Session.current }

  describe 'login process' do
    it 'successfully authenticates against the database' do
      expect(Neo4j::Session.current).to be_nil
      Neo4j::Session.open(:server_db, 'http://localhost:7474', basic_auth: { username: 'neo4j', password: @suite_default })
      expect(Neo4j::Session.current).not_to be_nil
    end

    it 'adds the authentication token header' do
      Neo4j::Session.open(:server_db, 'http://localhost:7474', basic_auth: { username: 'neo4j', password: @suite_default })
      expect(Neo4j::Session.current.connection.headers).to have_key('Authorization')
      expect(Neo4j::Session.current.connection.headers['Authorization']).not_to be_empty
    end

    it 'informs of a bad password' do
      expect { Neo4j::Session.open(:server_db, 'http://localhost:7474', basic_auth: { username: 'neo4j', password: 'foo' }) }
        .to raise_error Neo4j::Server::CypherAuthentication::InvalidPasswordError
    end

    it 'informs of missing credentials' do
      expect { Neo4j::Session.open(:server_db, 'http://localhost:7474') }.to raise_error Neo4j::Server::CypherAuthentication::MissingCredentialsError
    end

    it 'informs of a required password change' do
      response_double = double('A Faraday connection object')
      expect_any_instance_of(Faraday::Connection).to receive(:post).and_return(response_double)
      expect(response_double).to receive(:body).and_return({ 'password_change_required' => true })
      expect { Neo4j::Session.open(:server_db, 'http://localhost:7474', basic_auth: { username: 'neo4j', password: @suite_default }) }
        .to raise_error Neo4j::Server::CypherAuthentication::PasswordChangeRequiredError
    end
  end

  describe 'reauthentication' do
    it 'changes the token' do
      Neo4j::Session.open(:server_db, 'http://localhost:7474', basic_auth: { username: 'neo4j', password: 'neo4jrb rules, ok?' })
      expect(Neo4j::Session.current.auth.token).not_to be_nil
      starting_token = Neo4j::Session.current.auth.token
      Neo4j::Session.current.auth.reauthenticate('neo4jrb rules, ok?')
      expect(Neo4j::Session.current.auth.token).not_to be_nil
      expect(Neo4j::Session.current.auth.token).not_to eq starting_token
    end
  end

  describe 'password change' do
    let(:session) { Neo4j::Session.open(:server_db, 'http://localhost:7474', basic_auth: { username: 'neo4j', password: 'neo4jrb rules, ok?' }) }

    context 'with valid password' do
      after { Net::HTTP.post_form(@uri, { 'password' => 'neo4j', 'new_password' => @suite_default }) }

      it 'changes the password and does not give an error' do
        response = session.auth.change_password('neo4jrb rules, ok?', 'neo4j')
        expect(response).to be_a(Hash)
        expect(response['authorization_token']).not_to be_empty
      end
    end

    context 'with invalid password' do
      it 'does not change the password and returns the server error' do
        response = session.auth.change_password('neo4jrb rules, okzzz?', 'neo4j')
        expect(response).to be_a(Hash)
        expect(response['errors'][0]['code']).to eq 'Neo.ClientError.Security.AuthenticationFailed'
      end
    end
  end

  describe 'auth endpoint interaction' do
    let(:auth_object) { Neo4j::Server::CypherAuthentication.new('http://localhost:7474') }

    it 'can create a new, dedicated auth connection' do
      expect(auth_object.connection).to be_a(Faraday::Connection)
    end

    it 'allows manual setting of basic auth params' do
      expect(auth_object.params).to be_empty
      auth_object.basic_auth('neo4j', 'neo4jrb rules, ok?')
      expect(auth_object.params[:basic_auth][:username]).to eq 'neo4j'
      expect(auth_object.params[:basic_auth][:password]).to eq 'neo4jrb rules, ok?'
    end

    describe 'token invalidation' do
      it 'raises an error when a bad password is provided' do
        expect(auth_object.invalidate_token(:foo)['errors'][0]['code']).to eq 'Neo.ClientError.Security.AuthenticationFailed'
      end

      # Here, we're demonstrating that existing sessions with the server -- sessions with their own CypherAuthentication and Faraday::Connection objects --
      # are broken and required to reauthenticate when their tokens are invalidated.
      # We establish a new session, create a node, prove that it is valid and can be loaded, invalidate the token, and then get an error when we try
      # something that worked just a moment before.
      it 'invalidates existing tokens, breaking established connections' do
        Neo4j::Session.open(:server_db, 'http://localhost:7474', basic_auth: { username: 'neo4j', password: 'neo4jrb rules, ok?' })
        node = Neo4j::Node.create({ name: 'foo' }, :foo)
        expect(node.neo_id).to be_a(Integer)
        expect { Neo4j::Node.load(node.neo_id) }.not_to raise_error
        auth_object.invalidate_token('neo4jrb rules, ok?')
        expect { Neo4j::Node.load(node.neo_id) }.to raise_error
      end
    end
  end
end