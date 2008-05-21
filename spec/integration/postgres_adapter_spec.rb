require File.expand_path(File.join(File.dirname(__FILE__), '..', 'spec_helper'))

if HAS_POSTGRES
  describe DataMapper::Adapters::DataObjectsAdapter do
    before :all do
      @adapter = repository(:postgres).adapter
    end

    describe "auto migrating" do
      before :all do
        class Sputnik
          include DataMapper::Resource

          property :id, Integer, :serial => true
          property :name, DM::Text
        end
      end

      it "#upgrade_model should work" do
        @adapter.destroy_model_storage(nil, Sputnik)
        @adapter.storage_exists?("sputniks").should be_false
        Sputnik.auto_migrate!(:postgres)
        @adapter.storage_exists?("sputniks").should be_true
        @adapter.field_exists?("sputniks", "new_prop").should be_false
        Sputnik.property :new_prop, Integer, :serial => true
        @adapter.send(:drop_sequence, Sputnik, Sputnik.new_prop)
        Sputnik.auto_upgrade!(:postgres)
        @adapter.field_exists?("sputniks", "new_prop").should == true
      end
    end

    describe "querying metadata" do
      before do
        class Sputnik
          include DataMapper::Resource

          property :id, Integer, :serial => true
          property :name, DM::Text
        end

        Sputnik.auto_migrate!(:postgres)
      end

      it "#storage_exists? should return true for tables that exist" do
        @adapter.storage_exists?("sputniks").should == true
      end

      it "#storage_exists? should return false for tables that don't exist" do
        @adapter.storage_exists?("space turds").should == false
      end

      it "#field_exists? should return true for columns that exist" do
        @adapter.field_exists?("sputniks", "name").should == true
      end

      it "#field_exists? should return false for columns that don't exist" do
        @adapter.field_exists?("sputniks", "plur").should == false
      end
    end

    describe "handling transactions" do
      before :all do
        class Sputnik
          include DataMapper::Resource

          property :id, Integer, :serial => true
          property :name, DM::Text
        end

        Sputnik.auto_migrate!(:postgres)
      end

      before do
        @transaction = DataMapper::Transaction.new(@adapter)
      end

      it "should rollback changes when #rollback_transaction is called" do
        @transaction.commit do |trans|
          @adapter.execute("INSERT INTO sputniks (name) VALUES ('my pretty sputnik')")
          trans.rollback
        end
        @adapter.query("SELECT * FROM sputniks WHERE name = 'my pretty sputnik'").empty?.should == true
      end

      it "should commit changes when #commit_transaction is called" do
        @transaction.commit do
          @adapter.execute("INSERT INTO sputniks (name) VALUES ('my pretty sputnik')")
        end
        @adapter.query("SELECT * FROM sputniks WHERE name = 'my pretty sputnik'").size.should == 1
      end
    end

    describe "reading & writing a database" do
      before do
        class User
          include DataMapper::Resource

          property :id, Integer, :serial => true
          property :name, DM::Text
        end

        User.auto_migrate!(:postgres)

        @adapter.execute("INSERT INTO users (name) VALUES ('Paul')")
      end

      it 'should be able to #execute an arbitrary query' do
        result = @adapter.execute("INSERT INTO users (name) VALUES ('Sam')")

        result.affected_rows.should == 1
      end

      it 'should be able to #query' do
        result = @adapter.query("SELECT * FROM users")

        result.should be_kind_of(Array)
        row = result.first
        row.should be_kind_of(Struct)
        row.members.should == %w{id name}

        row.id.should == 1
        row.name.should == 'Paul'
      end

      it 'should return an empty array if #query found no rows' do
        @adapter.execute("DELETE FROM users")

        result = nil
        lambda { result = @adapter.query("SELECT * FROM users") }.should_not raise_error

        result.should be_kind_of(Array)
        result.size.should == 0
      end
    end

    describe "CRUD for serial Key" do
      before do
        class VideoGame
          include DataMapper::Resource

          property :id, Integer, :serial => true
          property :name, String
        end

        VideoGame.auto_migrate!(:postgres)
      end

      it 'should be able to create a record' do
        game = VideoGame.new(:name => 'System Shock')
        repository(:postgres) do
          game.save
        end

        game.should_not be_a_new_record
        game.should_not be_dirty

        @adapter.query('SELECT "id" FROM "video_games" WHERE "name" = ?', game.name).first.should == game.id
        @adapter.execute('DELETE FROM "video_games" WHERE "id" = ? RETURNING id', game.id).to_i.should == 1
      end

      it 'should be able to read a record' do
        name = 'Wing Commander: Privateer'
        id = @adapter.execute('INSERT INTO "video_games" ("name") VALUES (?) RETURNING id', name).insert_id

        game = repository(:postgres) do
          VideoGame.get(id)
        end

        game.name.should == name
        game.should_not be_dirty
        game.should_not be_a_new_record

        @adapter.execute('DELETE FROM "video_games" WHERE "name" = ?', name)
      end

      it 'should be able to update a record' do
        name = 'Resistance: Fall of Mon'
        id = @adapter.execute('INSERT INTO "video_games" ("name") VALUES (?) RETURNING id', name).insert_id

        game = repository(:postgres) do
          VideoGame.get(id)
        end

        game.should_not be_a_new_record

        game.should_not be_dirty
        game.name = game.name.sub(/Mon/, 'Man')
        game.should be_dirty

        repository(:postgres) do
          game.save
        end

        game.should_not be_dirty

        clone = repository(:postgres) do
          VideoGame.get(id)
        end

        clone.name.should == game.name

        @adapter.execute('DELETE FROM "video_games" WHERE "id" = ?', id)
      end

      it 'should be able to delete a record' do
        name = 'Zelda'
        id = @adapter.execute('INSERT INTO "video_games" ("name") VALUES (?) RETURNING id', name).insert_id

        game = repository(:postgres) do
          VideoGame.get(id)
        end

        game.name.should == name

        repository(:postgres) do
          game.destroy.should be_true
        end

        game.should be_a_new_record
        game.should be_dirty
      end

      it 'should respond to Resource#get' do
        name = 'Contra'
        id = @adapter.execute('INSERT INTO "video_games" ("name") VALUES (?) RETURNING id', name).insert_id

        contra = repository(:postgres) { VideoGame.get(id) }

        contra.should_not be_nil
        contra.should_not be_dirty
        contra.should_not be_a_new_record
        contra.id.should == id
      end
    end

    describe "CRUD for Composite Key" do
      before do
        class BankCustomer
          include DataMapper::Resource

          property :bank, String, :key => true
          property :account_number, String, :key => true
          property :name, String
        end

        BankCustomer.auto_migrate!(:postgres)
      end

      it 'should be able to create a record' do
        customer = BankCustomer.new(:bank => 'Community Bank', :account_number => '123456', :name => 'David Hasselhoff')
        repository(:postgres) do
          customer.save
        end

        customer.should_not be_a_new_record
        customer.should_not be_dirty

        row = @adapter.query('SELECT "bank", "account_number" FROM "bank_customers" WHERE "name" = ?', customer.name).first
        row.bank.should == customer.bank
        row.account_number.should == customer.account_number
      end

      it 'should be able to read a record' do
        bank, account_number, name = 'Chase', '4321', 'Super Wonderful'
        @adapter.execute('INSERT INTO "bank_customers" ("bank", "account_number", "name") VALUES (?, ?, ?)', bank, account_number, name)

        repository(:postgres) do
          BankCustomer.get(bank, account_number).name.should == name
        end

        @adapter.execute('DELETE FROM "bank_customers" WHERE "bank" = ? AND "account_number" = ?', bank, account_number)
      end

      it 'should be able to update a record' do
        bank, account_number, name = 'Wells Fargo', '00101001', 'Spider Pig'
        @adapter.execute('INSERT INTO "bank_customers" ("bank", "account_number", "name") VALUES (?, ?, ?)', bank, account_number, name)

        customer = repository(:postgres) do
          BankCustomer.get(bank, account_number)
        end

        customer.name = 'Bat-Pig'

        customer.should_not be_a_new_record
        customer.should be_dirty

        customer.save

        customer.should_not be_dirty

        clone = repository(:postgres) do
          BankCustomer.get(bank, account_number)
        end

        clone.name.should == customer.name

        @adapter.execute('DELETE FROM "bank_customers" WHERE "bank" = ? AND "account_number" = ?', bank, account_number)
      end

      it 'should be able to delete a record' do
        bank, account_number, name = 'Megacorp', 'ABC', 'Flash Gordon'
        @adapter.execute('INSERT INTO "bank_customers" ("bank", "account_number", "name") VALUES (?, ?, ?)', bank, account_number, name)

        customer = repository(:postgres) do
          BankCustomer.get(bank, account_number)
        end

        customer.name.should == name

        repository(:postgres) do
          customer.destroy.should be_true
        end

        customer.should be_a_new_record
        customer.should be_dirty
      end

      it 'should respond to Resource#get' do
        bank, account_number, name = 'Conchords', '1100101', 'Robo Boogie'
        @adapter.execute('INSERT INTO "bank_customers" ("bank", "account_number", "name") VALUES (?, ?, ?)', bank, account_number, name)

        robots = repository(:postgres) { BankCustomer.get(bank, account_number) }

        robots.should_not be_nil
        robots.should_not be_dirty
        robots.should_not be_a_new_record
        robots.bank.should == bank
        robots.account_number.should == account_number
      end
    end

    describe "Ordering a Query" do
      before do
        class SailBoat
          include DataMapper::Resource
          property :id, Integer, :serial => true
          property :name, String
          property :port, String
        end

        SailBoat.auto_migrate!(:postgres)

        repository(:postgres) do
          SailBoat.create(:id => 1, :name => "A", :port => "C")
          SailBoat.create(:id => 2, :name => "B", :port => "B")
          SailBoat.create(:id => 3, :name => "C", :port => "A")
        end
      end

      it "should order results" do
        repository(:postgres) do
          result = SailBoat.all(:order => [
              DataMapper::Query::Direction.new(SailBoat.properties[:name], :asc)
          ])
          result[0].id.should == 1

          result = SailBoat.all(:order => [
              DataMapper::Query::Direction.new(SailBoat.properties[:port], :asc)
          ])
          result[0].id.should == 3

          result = SailBoat.all(:order => [
              DataMapper::Query::Direction.new(SailBoat.properties[:name], :asc),
              DataMapper::Query::Direction.new(SailBoat.properties[:port], :asc)
          ])
          result[0].id.should == 1

          result = SailBoat.all(:order => [
              SailBoat.properties[:name],
              DataMapper::Query::Direction.new(SailBoat.properties[:port], :asc)
          ])
          result[0].id.should == 1
        end
      end
    end

    describe "Lazy Loaded Properties" do
      before do
        class SailBoat
          include DataMapper::Resource
          property :id, Integer, :serial => true
          property :notes, String, :lazy => [:notes]
          property :trip_report, String, :lazy => [:notes,:trip]
          property :miles, Integer, :lazy => [:trip]
        end

        SailBoat.auto_migrate!(:postgres)

        repository(:postgres) do
          SailBoat.create(:id => 1, :notes=>'Note',:trip_report=>'Report',:miles=>23)
          SailBoat.create(:id => 2, :notes=>'Note',:trip_report=>'Report',:miles=>23)
          SailBoat.create(:id => 3, :notes=>'Note',:trip_report=>'Report',:miles=>23)
        end
      end

      it "should lazy load" do
        result = repository(:postgres) do
          SailBoat.all
        end

        result[0].instance_variables.should_not include('@notes')
        result[0].instance_variables.should_not include('@trip_report')
        result[1].instance_variables.should_not include('@notes')
        result[0].notes.should_not be_nil
        result[1].instance_variables.should include('@notes')
        result[1].instance_variables.should include('@trip_report')
        result[1].instance_variables.should_not include('@miles')

        result = repository(:postgres) do
          SailBoat.all
        end

        result[0].instance_variables.should_not include('@trip_report')
        result[0].instance_variables.should_not include('@miles')

        result[1].trip_report.should_not be_nil
        result[2].instance_variables.should include('@miles')
      end
    end

    describe "finders" do
      before do
        class SerialFinderSpec
          include DataMapper::Resource

          property :id, Integer, :serial => true
          property :sample, String
        end

        SerialFinderSpec.auto_migrate!(:postgres)

        repository(:postgres) do
          100.times do
            SerialFinderSpec.create(:sample => rand.to_s)
          end
        end
      end

      it "should return all available rows" do
        repository(:postgres) do
          SerialFinderSpec.all.should have(100).entries
        end
      end

      it "should allow limit and offset" do
        repository(:postgres) do
          SerialFinderSpec.all(:limit => 50).should have(50).entries

          SerialFinderSpec.all(:limit => 20, :offset => 40).map(&:id).should == SerialFinderSpec.all[40...60].map(&:id)
        end
      end

      it "should lazy-load missing attributes" do
        sfs = repository(:postgres) do
          SerialFinderSpec.first(:fields => [ :id ])
        end

        sfs.should be_a_kind_of(SerialFinderSpec)
        sfs.should_not be_a_new_record

        sfs.instance_variables.should_not include('@sample')
        sfs.sample.should_not be_nil
      end

      it "should translate an Array to an IN clause" do
        ids = repository(:postgres) do
          SerialFinderSpec.all(:limit => 10).map(&:id)
        end

        results = repository(:postgres) do
          SerialFinderSpec.all(:id => ids)
        end

        results.size.should == 10
        results.map(&:id).should == ids
      end
    end

    describe "many_to_one associations" do
      before do
        class Engine
          include DataMapper::Resource

          property :id, Integer, :serial => true
          property :name, String
        end

        Engine.auto_migrate!(:postgres)

        @adapter.execute('INSERT INTO "engines" ("id", "name") values (?, ?)', 1, 'engine1')
        @adapter.execute('INSERT INTO "engines" ("id", "name") values (?, ?)', 2, 'engine2')

        class Yard
          include DataMapper::Resource

          property :id, Integer, :serial => true
          property :name, String
          property :engine_id, Integer

          repository(:postgres) do
            many_to_one :engine
          end
        end


        Yard.auto_migrate!(:postgres)

        @adapter.execute('INSERT INTO "yards" ("id", "name", "engine_id") values (?, ?, ?)', 1, 'yard1', 1)
      end

      it "should load without the parent"

      it 'should allow substituting the parent' do
        repository(:postgres) do
          y = Yard.first(:id => 1)
          e = Engine.first(:id => 2)
          y.engine = e
          y.save
        end

        repository(:postgres) do
          Yard.first(:id => 1).engine_id.should == 2
        end
      end

      it "#many_to_one" do
        yard = Yard.new
        yard.should respond_to(:engine)
        yard.should respond_to(:engine=)
      end

      it "should load the associated instance" do
        y = repository(:postgres) do
          Yard.first(:id => 1)
        end
        y.engine.should_not be_nil
        y.engine.id.should == 1
        y.engine.name.should == "engine1"
      end

      it 'should save the association key in the child' do
        repository(:postgres) do
          e = Engine.first(:id => 2)
          Yard.create(:id => 2, :name => 'yard2', :engine => e)
        end

        repository(:postgres) do
          Yard.first(:id => 2).engine_id.should == 2
        end
      end

      it 'should save the parent upon saving of child' do
        repository(:postgres) do
          e = Engine.new(:id => 10, :name => "engine10")
          y = Yard.new(:id => 10, :name => "Yard10", :engine => e)
          y.save

          y.engine_id.should == 10
        end

        repository(:postgres) do
          Engine.first(:id => 10).should_not be_nil
        end
      end
    end

    describe "one_to_many associations" do
      before do
        class Host
          include DataMapper::Resource

          property :id, Integer, :serial => true
          property :name, String

          repository(:postgres) do
            one_to_many :slices
          end
        end

        class Slice
          include DataMapper::Resource

          property :id, Integer, :serial => true
          property :name, String
          property :host_id, Integer

          repository(:postgres) do
            many_to_one :host
          end
        end

        Host.auto_migrate!(:postgres)

        @adapter.execute('INSERT INTO "hosts" ("id", "name") values (?, ?)', 1, 'host1')
        @adapter.execute('INSERT INTO "hosts" ("id", "name") values (?, ?)', 2, 'host2')

        Slice.auto_migrate!(:postgres)

        @adapter.execute('INSERT INTO "slices" ("id", "name", "host_id") values (?, ?, ?)', 1, 'slice1', 1)
        @adapter.execute('INSERT INTO "slices" ("id", "name", "host_id") values (?, ?, ?)', 2, 'slice2', 1)
      end

      it "#one_to_many" do
        h = Host.new
        h.should respond_to(:slices)
      end

      it "should allow removal of a child through a loaded association" do
        h = repository(:postgres) do
          Host.first(:id => 1)
        end

        s = h.slices.first

        h.slices.delete(s)
        h.slices.size.should == 1

        s = repository(:postgres) do
          Slice.first(:id => s.id)
        end

        s.host.should be_nil
        s.host_id.should be_nil
      end

      it "should load the associated instances" do
        h = repository(:postgres) do
          Host.first(:id => 1)
        end

        h.slices.should_not be_nil
        h.slices.size.should == 2
        h.slices.first.id.should == 1
        h.slices.last.id.should == 2
      end

      it "should add and save the associated instance" do
        repository(:postgres) do
          h = Host.first(:id => 1)

          h.slices << Slice.new(:id => 3, :name => 'slice3')

          s = repository(:postgres) do
            Slice.first(:id => 3)
          end

          s.host.id.should == 1
        end
      end

      it "should not save the associated instance if the parent is not saved" do
        repository(:postgres) do
          h = Host.new(:id => 10, :name => "host10")
          h.slices << Slice.new(:id => 10, :name => 'slice10')
        end

        repository(:postgres) do
          Slice.first(:id => 10).should be_nil
        end
      end

      it "should save the associated instance upon saving of parent" do
        repository(:postgres) do
          h = Host.new(:id => 10, :name => "host10")
          h.slices << Slice.new(:id => 10, :name => 'slice10')
          h.save
        end

        s = repository(:postgres) do
          Slice.first(:id => 10)
        end

        s.should_not be_nil
        s.host.should_not be_nil
        s.host.id.should == 10
      end
    end
  end
end
