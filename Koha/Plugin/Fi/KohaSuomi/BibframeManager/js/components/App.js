// Main App Component
const { onMounted } = Vue;
import { useBibframeStore } from '../store/index.js';
import { useEntityHelpers, useFileOperations } from '../composables/utils.js';
import PropertySuggestions from './PropertySuggestions.js';
import EntityCard from './EntityCard.js';
import OutputViewer from './OutputViewer.js';
import SearchRecords from './SearchRecords.js';

export default {
    name: 'BibframeApp',
    components: {
        PropertySuggestions,
        EntityCard,
        OutputViewer,
        SearchRecords
    },
    setup() {
        const store = useBibframeStore();
        const { getEntityIcon } = useEntityHelpers();
        
        onMounted(() => {
            store.generateRecordId();
        });
        
        return {
            store,
            getEntityIcon
        };
    },
    template: `
        <div class="container-fluid mt-4">
            <div class="row">
                <div class="col-12">
                    <h2><i class="fas fa-project-diagram"></i> Bibframe Record Builder</h2>
                    <p class="text-muted">Create Finnish BIBFRAME (Bibframe) records from scratch using the four-level RDA structure</p>
                    <hr>
                </div>
            </div>

            <!-- Alerts -->
            <div class="row" v-if="store.error">
                <div class="col-12">
                    <div class="alert alert-danger alert-dismissible fade show" role="alert">
                        <strong><i class="fas fa-exclamation-triangle"></i> Error!</strong> {{ store.error }}
                        <button type="button" class="btn-close" @click="store.clearError()" aria-label="Close"></button>
                    </div>
                </div>
            </div>

            <div class="row" v-if="store.success">
                <div class="col-12">
                    <div class="alert alert-success alert-dismissible fade show" role="alert">
                        <strong><i class="fas fa-check-circle"></i> Success!</strong> {{ store.success }}
                        <button type="button" class="btn-close" @click="store.clearSuccess()" aria-label="Close"></button>
                    </div>
                </div>
            </div>

            <div class="row">
                <!-- Left Sidebar-->
                <div class="col-md-3">
                    <SearchRecords />
                </div>

                <!-- Main Content -->
                <div class="col-md-9">
                    <!-- Configuration Section -->
                    <div class="card mb-4">
                        <div class="card-body">
                            <h5 class="card-title"><i class="fas fa-cog"></i> Configuration</h5>
                            <div class="row">
                                <div class="col-md-4">
                                    <label class="form-label">Record ID</label>
                                    <input v-model="store.recordId" type="text" class="form-control" placeholder="Enter Record ID">
                                </div>
                                <div class="col-md-4">
                                    <label class="form-label">Base URI</label>
                                    <input v-model="store.baseUri" type="text" class="form-control">
                                </div>
                                <div class="col-md-4">
                                    <label class="form-label">Output Format</label>
                                    <select v-model="store.outputFormat" class="form-select">
                                        <option value="turtle">Turtle (.ttl)</option>
                                        <option value="json-ld">JSON-LD (.jsonld)</option>
                                        <option value="ntriples">N-Triples (.nt)</option>
                                        <option value="rdf-xml">RDF/XML (.rdf)</option>
                                    </select>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- Add Entity Buttons -->
                    <div class="entity-type-selector">
                        <div class="entity-type-btn" @click="store.addEntity('work')">
                            <i class="fas fa-book fa-2x text-primary"></i>
                            <h5>Work</h5>
                            <small>Abstract creation</small>
                        </div>
                        <div class="entity-type-btn" @click="store.addEntity('expression')">
                            <i class="fas fa-file-alt fa-2x text-success"></i>
                            <h5>Expression</h5>
                            <small>Specific realization</small>
                        </div>
                        <div class="entity-type-btn" @click="store.addEntity('manifestation')">
                            <i class="fas fa-box fa-2x text-warning"></i>
                            <h5>Manifestation</h5>
                            <small>Physical embodiment</small>
                        </div>
                        <div class="entity-type-btn" @click="store.addEntity('item')">
                            <i class="fas fa-barcode fa-2x text-danger"></i>
                            <h5>Item</h5>
                            <small>Single copy</small>
                        </div>
                    </div>

                    <!-- Entities -->
                    <div v-if="store.entities.length === 0" class="text-center text-muted p-5">
                        <i class="fas fa-plus-circle fa-4x mb-3"></i>
                        <p>Click above to add your first entity</p>
                    </div>

                    <EntityCard 
                        v-for="(entity, index) in store.entities" 
                        :key="index"
                        :entity="entity"
                        :entityIndex="index"
                    />

                    <!-- Action Buttons -->
                    <div class="d-flex gap-2 mb-4" v-if="store.entities.length > 0">
                        <button @click="store.generateBibframe()" class="btn btn-primary">
                            <i class="fas fa-magic"></i> Generate Bibframe
                        </button>
                        <button @click="store.resetForm()" class="btn btn-outline-danger">
                            <i class="fas fa-redo"></i> Reset Form
                        </button>
                    </div>

                    <!-- Output Viewer -->
                    <OutputViewer />
                </div>
            </div>
        </div>
    `
};
