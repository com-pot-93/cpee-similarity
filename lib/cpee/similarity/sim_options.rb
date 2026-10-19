require 'damerau-levenshtein'
require 'rag_embeddings'
require 'daru'
require 'hungarian_algorithm_c'
require_relative '../../../../cpee-transformation/lib/cpee/transformation/transformer'
require_relative '../../../../cpee-transformation/lib/cpee/transformation/cpee'
require_relative 'all_functions'
# disable Logging, rag_emb uses langchain
Langchain.logger.level = Logger::UNKNOWN

module SimOptions

  def calculate_task_similarity(ftasks,ltasks,threshold)
    orig_sim_matrix = create_sim_matrix(ftasks,ltasks)
    sim_matrix = make_square_matrix(orig_sim_matrix)
    df = Daru::DataFrame.rows(orig_sim_matrix)
    #for reverse hungarian
    max_val = sim_matrix.flatten.max
    cost = sim_matrix.map { |row| row.map { |v| max_val - v } }
    begin
      hung_output = HungarianAlgorithmC.find_pairings(cost)
    rescue SystemStackError => e
      raise "optiomal solution can't be found!!!"
    end

    task_pairs = hung_output.to_h
    sum = 0
    task_pairs.each do |key, val|
      sim_val = df.row[key][val] rescue nil
      if sim_val && sim_val > threshold
        sum += sim_val
      else
        task_pairs[key] = "XXX"
      end
    end

    task_sim = sum.to_f/[ftasks.length,ltasks.length].max
    return task_sim, task_pairs
  end

  def task_similarity(doc1,doc2,threshold=0.7)
    threshold = threshold.nil? ? 0.7 : threshold.to_f
    begin
      ftraces, ftasks = process_model(doc1)
      ltraces, ltasks = process_model(doc2)
    rescue Timeout::Error => e
      raise "Timeout error!!!"
    end
    raise "at least one of the models does not have tasks" if ftasks.empty? || ltasks.empty?
    task_sim, task_pairs = calculate_task_similarity(ftasks,ltasks,threshold)
    return task_sim, task_pairs
  end

  def trace_similarity(doc1,doc2,threshold=0.7)
    threshold = threshold.nil? ? 0.7 : threshold.to_f
    begin
      ftraces, ftasks = process_model(doc1)
      ltraces, ltasks = process_model(doc2)
      ftraces = ftraces.uniq
      ltraces = ltraces.uniq
    rescue Timeout::Error => e
      raise "Timeout error!!!"
    end
    raise "at least one of the models does not have traces" if ftraces.empty? || ltraces.empty?
    task_sim, task_pairs = calculate_task_similarity(ftasks,ltasks,threshold)

    new_ftraces = []
    ftraces.each do |t|
      ids = t.select{ |el| el.type == :task }.map{ |el| el.id}
      trace = []
      ids.each do |id|
        ind = ftasks.keys.index(id)
        trace << task_pairs.keys.index(ind)
      end
      new_ftraces << trace
    end
    new_ftraces = new_ftraces.uniq

    new_ltraces = []
    ltraces.each do |t|
      ids = t.select{ |el| el.type == :task }.map{ |el| el.id}
      trace = []
      ids.each do |id|
        ind = ltasks.keys.index(id)
        temp = task_pairs.values.index(ind)
        if temp.nil?
          temp = ind + ltasks.length
        end
        trace << temp
      end
      new_ltraces << trace
    end
    new_ltraces = new_ltraces.uniq

    lev_matrix = create_lev_matrix(new_ftraces,new_ltraces)
    square_lev_matrix = make_square_matrix(lev_matrix)
    df = Daru::DataFrame.rows(lev_matrix)

    begin
      hung_output = HungarianAlgorithmC.find_pairings(square_lev_matrix)
    rescue SystemStackError => e
      raise "optiomal solution can't be found!!!"
    rescue => e
      raise "optiomal solution can't be found!!!"
    end

    trace_pairs =  hung_output.to_h
    sum = 0
    trace_pairs.each do |s,l|
      begin
        val =  df.row[s][l.to_i]
        maxi = [new_ftraces[s].length, new_ltraces[l.to_i].length].max
        percent = 1 - (val.to_f/maxi)
        sum = sum + percent
      rescue
        #do nothing
      end
    end
    trace_sim = sum/[lev_matrix.length, lev_matrix[0].length].max
    #gateway_penalty
    trace_sim = trace_sim * (1 - control_flow_penalty(doc1,doc2))
    return trace_sim, task_sim
  end
end

