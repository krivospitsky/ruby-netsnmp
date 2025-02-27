# frozen_string_literal: true

require_relative "mib/parser"

module NETSNMP
  module MIB
    using IsNumericExtensions

    OIDREGEX = /^[\d.]*$/.freeze

    module_function

    MIBDIRS = ENV.fetch("MIBDIRS", File.join("/usr", "share", "snmp", "mibs"))
                 .split(":")
                 .flat_map { |dir| [dir, *Dir.glob(File.join(dir, "**", "*")).select(&File.method(:directory?))] }.uniq
    PARSER = Parser.new
    @parser_mutex = Mutex.new

    @modules_loaded = []
    @object_identifiers = {}
    @syntax={}

    # Translates na identifier, such as "sysDescr", into an OID
    def oid(identifier)
      prefix, *suffix = case identifier
                        when Array
                          identifier.map(&:to_s)
                        else
                          identifier.split(".", 2).map(&:to_s)
                        end

      return unless prefix

      # early exit if it's an OID already
      unless prefix.integer?
        load_defaults
        # load module if need be
        idx = prefix.index("::")
        if idx
          mod = prefix[0..(idx - 1)]
          type = prefix[(idx + 2)..-1]
          return if mod && !module_loaded?(mod) && !load(mod)
        else
          type = prefix
        end

        return if type.nil? || type.empty?

        prefix = @object_identifiers[type] ||
                 raise(Error, "can't convert #{type} to OID")

      end

      [prefix, *suffix].join(".")
    end

    def identifier(oid)
      tmp=@object_identifiers.select do |_, ids_oid|
        oid==ids_oid
      end
      return tmp.first[0] if tmp.length>0
      return nil
  end

    #
    # Loads a MIB. Can be called multiple times, as it'll load it once.
    #
    # Accepts the MIB name in several ways:
    #
    #     MIB.load("SNMPv2-MIB")
    #     MIB.load("SNMPv2-MIB.txt")
    #     MIB.load("/path/to/SNMPv2-MIB.txt")
    #
    def load(mod)
      unless File.file?(mod)
        moddir = nil
        MIBDIRS.each do |mibdir|
          if File.exist?(File.join(mibdir, mod))
            moddir = File.join(mibdir, mod)
            break
          elsif File.extname(mod).empty? && File.exist?(File.join(mibdir, "#{mod}.txt"))
            moddir = File.join(mibdir, "#{mod}.txt")
            break
          end
        end
        return false unless moddir

        mod = moddir
      end
      return true if @modules_loaded.include?(mod)

      do_load(mod)
      @modules_loaded << mod
      true
    end

    def module_loaded?(mod)
      if File.file?(mod)
        @modules_loaded.include?(mod)
      else
        @modules_loaded.map { |path| File.basename(path, ".*") }.include?(mod)
      end
    end

    TYPES = ["OBJECT IDENTIFIER", "OBJECT-TYPE", "MODULE-IDENTITY", "OBJECT-IDENTITY"].freeze

    STATIC_MIB_TO_OID = {
      "iso" => "1"
    }.freeze

    #
    # Loads the MIB all the time, where +mod+ is the absolute path to the MIB.
    #
    def do_load(mod)
      data = @parser_mutex.synchronize { PARSER.parse(File.read(mod)) }

      imports = load_imports(data[:imports])

      declarations = Hash[
        data[:declarations].reject { |dec| !dec.key?(:name) || !TYPES.include?(dec[:type]) }
                           .map { |dec| [String(dec[:name]), [String(dec[:value]).split(/ +/), dec[:syntax]]]}
      ]

      declarations.each do |nme, value|
        store_oid_in_identifiers(nme, value[0], imports: imports, declarations: declarations)
        store_syntax(nme.to_s, value[1])
      end

      syntax = data[:declarations].reject { |dec| !dec.key?(:vartype) || !dec.key?(:syntax) }

      syntax.each do |type|
        store_syntax(type[:vartype].to_s, type[:syntax])
      end
    end

    def store_oid_in_identifiers(nme, value, imports:, declarations:)
      oid = value.flat_map do |cp|
        if cp.integer?
          cp
        elsif @object_identifiers.key?(cp)
          @object_identifiers[cp]
        elsif declarations.key?(cp)
          store_oid_in_identifiers(cp, declarations[cp][0], imports: imports, declarations: declarations)
          @object_identifiers[cp]
        else
          STATIC_MIB_TO_OID[cp] || begin
            imported_mod, = if imports
                              imports.find do |_, identifiers|
                                identifiers.include?(cp)
                              end
                            end

            raise Error, "didn't find a module to import \"#{cp}\" from" unless imported_mod

            load(imported_mod)

            @object_identifiers[cp]
          end
        end
      end.join(".")

      @object_identifiers[nme] = oid
    end


    def store_syntax(nme, syntax)
      if syntax
          @syntax[nme]=syntax
      end
    end

    def get_syntax(name)
      s=@syntax[name]
      if s
          if s.is_a?(Hash) && s.key?(:value)
              s2=get_syntax(s[:value].to_s)
              if s2 && !s2.empty?
                  return s2
              else
                  return {name: name, syntax: s}
              end
          else
              return {name: name, syntax: s}
          end
      end
      return nil
    end

    def process_syntax(name, value)
      return value.inspect if value.is_a?(NETSNMP::HexString)
      return value.to_i if value.is_a?(NETSNMP::Timetick)

      syntax_obj=get_syntax(name)
      if syntax_obj
          syntax=syntax_obj[:syntax]
          if syntax.is_a?(Array)
              if syntax[0][:type]=='INTEGER'
                  syntax=Hash[syntax.select{|el| el[:enum]}.map{|enum| [enum[:enum][:value].to_i, enum[:enum][:name].to_s]}]
                  if syntax[value]
                      if syntax_obj[:name]=='CfgTypeBoolean' || syntax_obj[:name]=='TruthValue'
                          return syntax[value].to_b
                      else
                          return syntax[value]
                      end
                  end
              end
          end
      end
      return value
    end

    #
    # Reformats the import lists into an hash indexed by module name, to a list of
    # imported names
    #
    def load_imports(imports)
      return unless imports

      imports = [imports] unless imports.respond_to?(:to_ary)
      imports.each_with_object({}) do |import, imp|
        imp[String(import[:name])] = case import[:ids]
                                     when Hash
                                       [String(import[:ids][:name])]
                                     else
                                       import[:ids].map { |id| String(id[:name]) }
                                     end
      end
    end

    def load_defaults
      # loading the defaults MIBS
      load("SNMPv2-MIB")
      load("IF-MIB")
    end

    def freeze
      super
      @modules_loaded.each(&:freeze).freeze
      @object_identifiers.each_key(&:freeze).each_value(&:freeze).freeze
    end
  end
end
