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

  # matches two lists of elements with the hungarian algorithm, the block returns the pairwise similarity
  # returns the similarity and the size of the (soft) union, which is used as weight
  def calculate_element_similarity(felements,lelements,threshold)
    return 0, 0 if felements.empty? || lelements.empty?
    orig_sim_matrix = felements.map { |f| lelements.map { |l| yield(f, l) } }
    sim_matrix = make_square_matrix(orig_sim_matrix)
    #for reverse hungarian
    max_val = sim_matrix.flatten.max
    cost = sim_matrix.map { |row| row.map { |v| max_val - v } }
    begin
      hung_output = HungarianAlgorithmC.find_pairings(cost)
    rescue SystemStackError => e
      raise "optiomal solution can't be found!!!"
    end

    sum = 0
    matched = 0
    hung_output.to_h.each do |key, val|
      sim_val = orig_sim_matrix.dig(key, val)
      if sim_val && sim_val > threshold
        sum += sim_val
        matched += 1
      end
    end

    sim = sum.to_f/[felements.length,lelements.length].max
    union = felements.length + lelements.length - matched
    return sim, union
  end

  def element_similarity(doc1,doc2,threshold=0.7)
    threshold = threshold.nil? ? 0.7 : threshold.to_f
    begin
      felements = process_model_elements(doc1)
      lelements = process_model_elements(doc2)
    rescue Timeout::Error => e
      raise "Timeout error!!!"
    end

    sim = {}
    weight = {}
    felements.each_key do |category|
      sim[category], weight[category] = calculate_element_similarity(felements[category],lelements[category],threshold) do |f, l|
        case category
          when :task_names, :event_names, :gateway_names then text_similarity(f, l)
          when :sequence_flows then flow_similarity(f, l)
          else f == l ? 1.0 : 0.0
        end
      end
    end

    scores = {}
    scores[:overall] = weighted_score(sim.keys.map { |c| [sim[c], weight[c]] })
    scores[:tasks_overall] = weighted_score([[sim[:task_names], weight[:task_names]], [sim[:task_types], weight[:task_types]]])
    scores[:events_overall] = weighted_score([[sim[:event_names], weight[:event_names]], [sim[:event_types], weight[:event_types]]])
    scores[:gateways_overall] = weighted_score([[sim[:gateway_names], weight[:gateway_names]], [sim[:gateway_types], weight[:gateway_types]]])
    scores[:flows_overall] = sim[:sequence_flows]
    scores.merge!(sim)
    return scores[:overall], scores
  end
end

