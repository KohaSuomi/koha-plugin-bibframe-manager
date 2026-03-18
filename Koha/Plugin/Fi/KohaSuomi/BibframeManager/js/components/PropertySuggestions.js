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
    template: `
        <div class="sidebar">
            <h5><i class="fas fa-lightbulb"></i> Property Suggestions</h5>
            <hr>
            
            <!-- Work Properties -->
            <div class="mb-3">
                <h6 class="text-primary"><i class="fas fa-book"></i> Work Properties</h6>
                <div 
                    v-for="suggestion in store.propertySuggestions.work" 
                    :key="suggestion.value"
                    class="property-suggestion" 
                    @click="store.addPropertySuggestion('work', suggestion.value)"
                >
                    {{ suggestion.label }}
                </div>
            </div>

            <!-- Expression Properties -->
            <div class="mb-3">
                <h6 class="text-success"><i class="fas fa-file-alt"></i> Expression Properties</h6>
                <div 
                    v-for="suggestion in store.propertySuggestions.expression" 
                    :key="suggestion.value"
                    class="property-suggestion" 
                    @click="store.addPropertySuggestion('expression', suggestion.value)"
                >
                    {{ suggestion.label }}
                </div>
            </div>

            <!-- Manifestation Properties -->
            <div class="mb-3">
                <h6 class="text-warning"><i class="fas fa-box"></i> Manifestation Properties</h6>
                <div 
                    v-for="suggestion in store.propertySuggestions.manifestation" 
                    :key="suggestion.value"
                    class="property-suggestion" 
                    @click="store.addPropertySuggestion('manifestation', suggestion.value)"
                >
                    {{ suggestion.label }}
                </div>
            </div>

            <!-- Item Properties -->
            <div class="mb-3">
                <h6 class="text-danger"><i class="fas fa-barcode"></i> Item Properties</h6>
                <div 
                    v-for="suggestion in store.propertySuggestions.item" 
                    :key="suggestion.value"
                    class="property-suggestion" 
                    @click="store.addPropertySuggestion('item', suggestion.value)"
                >
                    {{ suggestion.label }}
                </div>
            </div>
        </div>
    `
};
