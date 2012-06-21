ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.class_eval do
  # Con esto nos reconoce correctamente los nombres de tabla perteneciente a un schema
  def quote_table_name(name)
    name
  end

  # Hacemos que se genere bien el archivo schemas.rb
  def tables(name = nil)
    schs = schema_search_path.split(',').map { |p| quote(p) }.join(',')
    query("SELECT tablename, schemaname FROM pg_tables WHERE schemaname IN (#{schs})", name).map{ |row|
      if row[0] == 'schema_migrations'
        row[0]
      else
        "#{row[1]}.#{row[0]}"
      end
    }
  end

  # Al establecer este parámetro, si no existe uno de los schemas indicados, se crea
  def schema_search_path=(schema_csv)
    # Sobrecargamos el método para crear los esquemas que se hayan especificado y no existan todavía
    if schema_csv
      # Sacamos el listado de los que hay actualmente
      existing_schemas = query("SELECT DISTINCT nspname FROM pg_namespace").map{ |es| es[0] }
      # Quitamos los "protegidos" de la cadena
      system_schemas = [ 'public', 'pg_catalog', 'schema_migrations', 'information_schema', 'pg_toast', 'pg_temp_1', 'pg_toast_temp_1' ]
      schema_csv = schema_csv.split(',').delete_if{ |x| system_schemas.include? x }
      # Creamos los que sean necesarios
      schema_csv.each do |s|
        execute "CREATE SCHEMA #{s}" unless existing_schemas.include? s
      end
      # Finalmente, establecemos el valor en el "search_path"
      schema_csv = schema_csv.join(',')
      schema_csv = "public,#{schema_csv}" unless schema_csv.include? 'public,' or schema_csv.blank?
      execute "SET search_path TO #{schema_csv}" unless schema_csv.blank?
      @schema_search_path = schema_csv
    end
  end
end

# Idem del anterior
ActiveRecord::ConnectionAdapters::AbstractAdapter.class_eval do
  def create_table(table_name, options = {})
    # Sólo si trabajamos con PostgreSQL
    if adapter_name == 'PostgreSQL'
      # Si el nombre de la tabla ya viene con el schema, se lo quitamos y lo guardamos
      if table_name.include? '.'
        schema_name = table_name.split('.')[0]
        table_name = table_name[(schema_name.length + 1)..-1]
      end
      schema_name = nil if table_name == 'schema_migrations'
      table_name = "#{schema_name}.#{table_name}" unless schema_name.blank?
      # Sacamos el listado completo de schemas
      existing_schemas = query("SELECT DISTINCT nspname FROM pg_namespace").map{ |es| es[0] }
      # Si no existe dicho schema, lo creamos
      execute "CREATE SCHEMA #{schema_name}" unless existing_schemas.blank? or schema_name.blank? or existing_schemas.include? schema_name
    end
    # Seguimos con el código de creación de tabla
    table_definition = ActiveRecord::ConnectionAdapters::TableDefinition.new(self)
    table_definition.primary_key(options[:primary_key] || ActiveRecord::Base.get_primary_key(table_name.to_s.singularize)) unless options[:id] == false
    yield table_definition
    # Sacamos el listado de tablas existentes
    existing_tables = query("SELECT tablename, schemaname FROM pg_tables WHERE tableowner != 'postgres'").map{ |row| "#{row[1]}.#{row[0]}" }
    existing_tables.each do |t|
      existing_tables.push t.split('.')[1] if t.include? '.'
    end
    existing_tables.uniq!
    # Tiramos la casa y la volvemos a construir
    drop_table table_name if (existing_tables.include? table_name or (options[:force] and existing_tables.include? table_name))
    execute "CREATE#{' TEMPORARY' if options[:temporary]} TABLE #{quote_table_name(table_name)} (#{table_definition.to_sql}) #{options[:options]}"
  end
end