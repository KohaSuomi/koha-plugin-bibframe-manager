// Property Suggestions Sidebar Component
import { useBibframeStore } from '../store/index.js';

export default {
    name: 'PropertySuggestions',
    setup() {
        const store = useBibframeStore();
        
        return {
            store
        };
    },
    computed: {
        entityTypes() {
            return this.store.standard === 'bibframe2'
                ? ['work', 'instance', 'item']
                : ['work', 'expression', 'manifestation', 'item'];
        }
    },
    template: `
        <div class="sidebar">
            <h5><i class="fas fa-lightbulb"></i> Property Suggestions</h5>
            <hr>
            
            <div v-for="type in entityTypes" :key="type" class="mb-3">
                <h6 class="text-primary"><i class="fas fa-tags"></i> {{ type.charAt(0).toUpperCase() + type.slice(1) }} Properties</h6>
                <div 
                    v-for="suggestion in store.getPropertySuggestions(type)" 
                    :key="suggestion.value"
                    class="property-suggestion" 
                    @click="store.addPropertySuggestion(type, suggestion.value)"
                >
                    {{ suggestion.label }}
                </div>
            </div>
        </div>
    `
};
