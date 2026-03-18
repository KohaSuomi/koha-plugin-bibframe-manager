// Entity Card Component
import { useBibframeStore } from '../store/index.js';
import { useEntityHelpers } from '../composables/utils.js';

export default {
    name: 'EntityCard',
    props: {
        entity: {
            type: Object,
            required: true
        },
        entityIndex: {
            type: Number,
            required: true
        }
    },
    setup(props) {
        const store = useBibframeStore();
        const { getEntityIcon, getEntityBadgeClass, getEntityDescription } = useEntityHelpers();
        
        return {
            store,
            getEntityIcon,
            getEntityBadgeClass,
            getEntityDescription
        };
    },
    template: `
        <div class="entity-card" :class="entity.type">
            <div class="entity-header">
                <div>
                    <h4>
                        <i :class="getEntityIcon(entity.type)"></i>
                        {{ entity.type.charAt(0).toUpperCase() + entity.type.slice(1) }}
                        <span class="badge" :class="'bg-' + getEntityBadgeClass(entity.type) + ' badge-entity'">
                            {{ entity.type }}
                        </span>
                    </h4>
                    <small class="text-muted">{{ getEntityDescription(entity.type) }}</small>
                </div>
                <button @click="store.removeEntity(entityIndex)" class="btn btn-sm btn-outline-danger">
                    <i class="fas fa-trash"></i> Remove
                </button>
            </div>
            
            <!-- URI Input -->
            <div class="mb-3">
                <label class="form-label">Entity URI (optional)</label>
                <input 
                    v-model="entity.uri" 
                    type="text" 
                    class="form-control" 
                    :placeholder="'Leave empty to auto-generate based on Record ID'"
                >
            </div>
            
            <!-- Properties Section -->
            <div class="mb-3">
                <h5><i class="fas fa-tags"></i> Properties</h5>
                <div v-for="(prop, propIndex) in entity.properties" :key="propIndex" class="d-flex gap-2 align-items-center mb-2">
                    <select v-model="prop.predicate" class="form-select">
                        <option value="">Select Property...</option>
                        <option v-for="suggestion in store.getPropertySuggestions(entity.type)" 
                                :key="suggestion.value" 
                                :value="suggestion.value">
                            {{ suggestion.label }}
                        </option>
                        <option value="custom">Custom Property...</option>
                    </select>
                    
                    <input 
                        v-if="prop.predicate === 'custom'" 
                        v-model="prop.customPredicate" 
                        type="text" 
                        class="form-control" 
                        style="width: 250px;"
                        placeholder="Custom predicate URI"
                    >
                    
                    <input 
                        v-model="prop.object" 
                        type="text" 
                        class="form-control flex-grow-1" 
                        placeholder="Value"
                    >
                    
                    <select v-model="prop.objectType" class="form-select" style="width: 120px;">
                        <option value="literal">Literal</option>
                        <option value="uri">URI</option>
                    </select>
                    
                    <button @click="store.removeProperty(entityIndex, propIndex)" class="btn btn-sm btn-danger">
                        <i class="fas fa-times"></i>
                    </button>
                </div>
                
                <button @click="store.addProperty(entityIndex)" class="btn btn-sm btn-outline-primary mt-2">
                    <i class="fas fa-plus"></i> Add Property
                </button>
            </div>
            
            <!-- Relationships Section -->
            <div>
                <h5><i class="fas fa-link"></i> Relationships</h5>
                <div v-for="(rel, relIndex) in entity.relationships" :key="relIndex" class="d-flex gap-2 align-items-center mb-2">
                    <select v-model="rel.predicate" class="form-select" style="width: 200px;">
                        <option value="">Select Relationship...</option>
                        <option value="bffi:hasExpression">hasExpression</option>
                        <option value="bffi:expressionOf">expressionOf</option>
                        <option value="bffi:manifestationOf">manifestationOf</option>
                        <option value="bffi:itemOf">itemOf</option>
                        <option value="bffi:relatedTo">relatedTo</option>
                        <option value="custom">Custom...</option>
                    </select>
                    
                    <input 
                        v-if="rel.predicate === 'custom'" 
                        v-model="rel.customPredicate" 
                        type="text" 
                        class="form-control" 
                        style="width: 250px;"
                        placeholder="Custom relationship URI"
                    >
                    
                    <input 
                        v-model="rel.targetUri" 
                        type="text" 
                        class="form-control flex-grow-1" 
                        placeholder="Target URI"
                    >
                    
                    <button @click="store.removeRelationship(entityIndex, relIndex)" class="btn btn-sm btn-danger">
                        <i class="fas fa-times"></i>
                    </button>
                </div>
                
                <button @click="store.addRelationship(entityIndex)" class="btn btn-sm btn-outline-primary mt-2">
                    <i class="fas fa-plus"></i> Add Relationship
                </button>
            </div>
        </div>
    `
};
