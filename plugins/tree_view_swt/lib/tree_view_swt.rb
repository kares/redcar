
module Redcar
  class TreeViewSWT
    attr_reader :viewer, :model
    
    def self.storage
      @storage ||= begin
         storage = Plugin::Storage.new('tree_view_swt_plugin')
         storage.set_default('refresh_trees_on_refocus', true)
         storage
      end
    end
    
    def initialize(composite, model)
      @composite, @model = composite, model
      tree_style = Swt::SWT::VIRTUAL | Swt::SWT::MULTI
      @viewer = JFace::Viewers::TreeViewer.new(@composite, tree_style)
      @viewer.set_content_provider(TreeMirrorContentProvider.new)
      @viewer.set_input(@model.tree_mirror)
      @viewer.set_label_provider(TreeMirrorLabelProvider.new)
      
      if @model.tree_controller
        @viewer.add_tree_listener(@viewer.getControl, TreeListener.new)
        @viewer.add_double_click_listener(DoubleClickListener.new)
        @viewer.add_open_listener(OpenListener.new(@model))
        control.add_mouse_listener(MouseListener.new(self))
      end
      
      register_dnd
      
      @model.add_listener(:refresh) { @viewer.refresh }
      
      @editor = Swt::Custom::TreeEditor.new(control)
      
      @editor.horizontalAlignment = Swt::SWT::LEFT
      @editor.grabHorizontal = true
      
      @model.add_listener(:edit_element, &method(:edit_element))
      @model.add_listener(:expand_element, &method(:expand_element))
      @model.add_listener(:select_element, &method(:select_element))
    end
    
    class DragSourceListener
      attr_reader :tree, :dragged_elements
      
      def initialize(tree_view_swt, tree)
        @tree_view_swt = tree_view_swt
        @tree = tree
      end
      
      def drag_start(event)
        selection = tree.get_selection
        if selection.length > 0
          event.doit = true
          @dragged_elements = selection.map do |item|
            @tree_view_swt.item_to_element(item)
          end
          Redcar.safely do
            @tree_view_swt.drag_controller.drag_start(@dragged_elements)
          end
        else
          event.doit = false
        end
      end
      
      def drag_set_data(event)
        case tree_mirror.data_type
        when :file
          Redcar.safely do
            @data = tree_mirror.to_data(dragged_elements).to_java(:string)
          end
          event.data = @data
        when :text
          Redcar.safely do
            @data = tree_mirror.to_data(dragged_elements)
          end
          event.data = @data
        else
          raise "unknown tree data_type #{tree.tree_mirror.data_type}"
        end
      end
      
      def drag_finished(*_); end
      
      def tree_mirror
        @tree_view_swt.model.tree_mirror
      end
    end
    
    class DropAdapter < JFace::Viewers::ViewerDropAdapter
      def initialize(tree_view_swt, drag_source_listener, viewer)
        @tree_view_swt = tree_view_swt
        @drag_source_listener = drag_source_listener
        super(viewer)
      end
      
      def validateDrop(target, operation, transfer_data_type)
        pos = location_to_position(get_current_location)
        Redcar.safely do
          @tree_view_swt.drag_controller.can_drop?(@drag_source_listener.dragged_elements, target, pos)
        end
      end
      
      def performDrop(data)
        elements = data.to_a.map {|datum| @tree_view_swt.model.tree_mirror.from_data(datum) }
        pos = location_to_position(get_current_location)
        Redcar.safely do
          @tree_view_swt.drag_controller.do_drop(elements, get_current_target, pos)
        end
        true
      end
      
      private
      
      def location_to_position(location)
        if Redcar.safely { @tree_view_swt.drag_controller.reorderable? }
          {1 => :before, 2 => :after, 3 => :onto}[location]
        else
          :onto
        end
      end
    end
    
    def register_dnd
      case Redcar.safely { @model.tree_mirror.data_type }
      when :file
        types = [Swt::DND::FileTransfer.getInstance()].to_java(:"org.eclipse.swt.dnd.FileTransfer")
      when :text
        types = [Swt::DND::TextTransfer.getInstance()].to_java(:"org.eclipse.swt.dnd.TextTransfer")
      else
        raise "unknown tree data_type #{Redcar.safely { tree.tree_mirror.data_type }}"
      end
      operations = Swt::DND::DND::DROP_MOVE | Swt::DND::DND::DROP_COPY
      
      source_listener = DragSourceListener.new(self, @viewer.get_tree)
      drop_adapter = DropAdapter.new(self, source_listener, @viewer)
      drop_adapter.set_feedback_enabled(drag_controller.reorderable?)
      
      @viewer.add_drag_support(operations, types, source_listener)
      @viewer.add_drop_support(operations, types, drop_adapter)
    end
    
    def drag_controller
      @model.tree_controller.drag_controller(@model)
    end
    
    def edit_element(element, select_from, select_to)
      item = element_to_item(element)
      unless item
        puts "ERROR: when trying to edit, no visible item for #{element.inspect}"
        return
      end
      
      text = Swt::Widgets::Text.new(control, Swt::SWT::NONE)
      text.set_text(item.get_text)
      colour = ApplicationSWT.display.get_system_color(Swt::SWT::COLOR_GRAY)
      text.set_background(colour)
      
      @editor.set_editor(text, item)
      text.set_selection(select_from || 0, select_to || text.get_text.length)
      listener = EditorListener.new(self, element, text)
      text.add_listener(Swt::SWT::FocusOut, listener)
      text.add_listener(Swt::SWT::Traverse, listener)

      text.set_focus
    end
    
    def edited_element(element, text)
      if @model.tree_controller and @model.tree_controller.respond_to?(:edited)
        Redcar.safely("edit element") do
          @model.tree_controller.edited(@model, element, text)
        end
      end
    end
    
    def expand_element(element)
      if item = element_to_item(element)
        @viewer.expandToLevel(element, 1)
      end
    end

    def select_element(element)
      if item = element_to_item(element)
        @viewer.get_tree.set_selection(item)
      end
    end

    def element_to_item(element)
      @viewer.test_find_item(element)
    end
    
    def item_to_element(item)
      @viewer.getViewerRowFromItem(item).get_element
    end
    
    def selection
      @viewer.get_tree.get_selection.map {|i| item_to_element(i) }
    end
    
    class EditorListener
      def initialize(tree_view_swt, element, text_widget)
        @tree_view_swt = tree_view_swt
        @element = element
        @text = text_widget
      end
      
      def handle_event(e)
        case e.type
        when Swt::SWT::FocusOut
          new_text = @text.get_text
          @text.dispose
          @tree_view_swt.edited_element(@element, new_text)
        when Swt::SWT::Traverse
          case e.detail
          when Swt::SWT::TRAVERSE_RETURN
            new_text = @text.get_text
            @text.dispose
            e.doit = false
            @tree_view_swt.edited_element(@element, new_text)
          when Swt::SWT::TRAVERSE_ESCAPE
            @text.dispose
            e.doit = false
          end
        end
      end
    end
    
    def control
      @viewer.get_control
    end
    
    def close
      @viewer.getControl.dispose
    end
    
    def right_click(mouse_event)
      if @model.tree_controller
        point = Swt::Graphics::Point.new(mouse_event.x, mouse_event.y)
        item = @viewer.get_item_at(point)
        element = item ? @viewer.getViewerRowFromItem(item).get_element : nil
        if @model.tree_controller.respond_to?(:right_click)
          Redcar.safely("right click on tree") do
            @model.tree_controller.right_click(@model, element)
          end
        end
      end
    end
    
    class TreeListener
      def tree_collapsed(e)
      end
      
      def tree_expanded(e)
      end
    end
    
    class SelectionListener
      def widget_default_selected(e)
      end
      
      def widget_selected(e)
      end
    end
    
    class MouseListener
      def initialize(tree_view_swt)
        @tree_view_swt = tree_view_swt
      end
      
      def mouse_double_click(_); end
      def mouse_up(_)
      end
      
      def mouse_down(e)
        if e.button == 3
          @tree_view_swt.right_click(e)
        end
      end
    end
    
    class DoubleClickListener
      def double_click(e)

        double_clicked_element = e.get_viewer.get_selection.get_first_element

        #do nothing for leaves
        return if double_clicked_element.leaf?

        viewer = e.get_viewer
        node_is_expanded = viewer.getExpandedState(double_clicked_element) 

        if node_is_expanded
          viewer.collapseToLevel(double_clicked_element, 1)
        else
          viewer.expandToLevel(double_clicked_element, 1)
        end
      end
    end
    
    class OpenListener
      def initialize(tree_model)
        @tree_model = tree_model
      end
      
      def open(e)
        Redcar.safely("tree row activation") do
          @tree_model.tree_controller.activated(@tree_model, e.getSelection.toArray.to_a.first)
        end
      end
    end
    
    class TreeMirrorContentProvider
      include JFace::Viewers::ITreeContentProvider

      def input_changed(viewer, _, tree_mirror)
        @viewer, @tree_mirror = viewer, tree_mirror
      end

      def get_elements(tree_mirror)
        tree_mirror.top.to_java
      end

      def has_children(tree_node)
        tree_node.children.any?
      end

      def get_children(tree_node)
        tree_node.children.to_java
      end
      
      def get_parent(tree_node)
        # not sure why this is necessary
      end

      def dispose
      end
    end

    class TreeMirrorLabelProvider
      include JFace::Viewers::ILabelProvider

      def add_listener(*_)
      end

      def remove_listener(*_)
      end

      def get_text(tree_node)
        tree_node.text
      end

      def get_image(tree_node)
        case tree_node.icon
        when :directory
          dir_image
        when :file
          file_image
        end
      end

      def dispose
      end
      
      private
      
      def dir_image
        @dir_image ||= begin
          path = File.join(Redcar.root, %w(plugins application icons darwin-folder.png))
          Swt::Graphics::Image.new(ApplicationSWT.display, path)
        end
      end
      
      def file_image
        @file_image ||= begin
          path = File.join(Redcar.root, %w(plugins application icons darwin-file.png))
          Swt::Graphics::Image.new(ApplicationSWT.display, path)
        end
      end
    end
  end
end
